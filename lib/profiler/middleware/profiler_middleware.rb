# frozen_string_literal: true

require_relative "../models/profile"
require_relative "../current_context"
require_relative "../collectors/lifecycle"
require_relative "toolbar_injector"

module Profiler
  module Middleware
    class ProfilerMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless should_profile?(env)

        collectors = nil
        begin
          begin
            profile = Models::Profile.new(build_request(env))
            profile.gem_version = Profiler::VERSION
            Profiler::CurrentContext.token = profile.token

            # Capture request body before app processes it
            req_body_raw = read_rack_input(env)

            # Store profile in env for collectors
            env["profiler.profile"] = profile

            collectors = create_collectors(profile)
            env["profiler.collectors"] = collectors
            subscribed = Collectors::Lifecycle.subscribe_all(collectors, "ProfilerMiddleware")
          rescue => e
            warn "Profiler error: #{e.message}\n#{e.backtrace.join("\n")}"
            subscribed = false
          end

          unless subscribed
            # The application has not run yet: serve the request once, unprofiled.
            release(collectors)
            return @app.call(env)
          end

          # Measure memory before
          memory_before = current_memory if Profiler.configuration.track_memory

          begin
            response = @app.call(env)
          rescue Exception => e # rubocop:disable Lint/RescueException
            record_failed_request(env, profile, collectors, req_body_raw, memory_before, e) if failed_request?(e)
            raise
          end

          complete_profile(env, profile, collectors, req_body_raw, memory_before, response)
        ensure
          # Opened before the first subscribe: whatever happens from there on, an exception
          # outside StandardError included, nothing a collector installed outlives the request.
          release(collectors)
        end
      end

      private

      def complete_profile(env, profile, collectors, req_body_raw, memory_before, response)
        status, headers, body = response
        headers = headers.dup

        # Measure memory after
        if Profiler.configuration.track_memory
          memory_after = current_memory
          profile.memory = memory_after - memory_before
        end

        body_content = collect_body(body)
        body = [body_content]

        profile.finish(status, headers)

        profile.set_bodies(
          request_body: req_body_raw,
          response_body: body_content,
          req_content_type: env["CONTENT_TYPE"].to_s,
          resp_content_type: (headers["content-type"] || headers["Content-Type"]).to_s
        )

        collect_all(profile, collectors)

        Profiler.storage.save(profile.token, profile)

        headers["X-Profiler-Token"] = profile.token

        if html_response?(headers)
          nonce = env['action_dispatch.content_security_policy_nonce']
          body = ToolbarInjector.new(body, profile.token, nonce).inject
        end

        [status, headers, body]
      rescue => e
        # The application has run: its response goes out, profiled or not.
        warn "Profiler error: #{e.message}\n#{e.backtrace.join("\n")}"
        [status, headers, body || []]
      end

      # A request cut short by a timeout (Timeout::ExitException, Rack::Timeout) is profiled like
      # one that raised; one stopped by a signal or an exit is not, the process is going away.
      def failed_request?(error)
        !error.is_a?(SignalException) && !error.is_a?(SystemExit)
      end

      # The profile of a request that raised is kept: status 500, which the server answers once
      # the exception leaves the stack, and the exception itself. Never masks the exception.
      def record_failed_request(env, profile, collectors, req_body_raw, memory_before, error)
        collectors.each { |collector| collector.capture(error) if collector.respond_to?(:capture) }
        profile.memory = current_memory - memory_before if Profiler.configuration.track_memory
        profile.finish(500)
        profile.set_bodies(
          request_body: req_body_raw,
          response_body: "",
          req_content_type: env["CONTENT_TYPE"].to_s,
          resp_content_type: ""
        )
        collect_all(profile, collectors)
        Profiler.storage.save(profile.token, profile)
      rescue => e
        warn "Profiler error while recording a failed request: #{e.message}"
      end

      def collect_all(profile, collectors)
        collectors.each do |collector|
          begin
            collector.collect if collector.respond_to?(:collect)
            profile.add_collector_metadata(collector)
          rescue => e
            warn "Collector #{collector.class} failed: #{e.message}"
          end
        end
      end

      def release(collectors)
        Collectors::Lifecycle.release_all(collectors)
        Profiler::CurrentContext.clear
      end

      def should_profile?(env)
        return false unless Profiler.enabled?

        request = build_request(env)
        return false unless Profiler.configuration.authorized?(request)

        # Skip profiler's own paths and static assets
        path = env["PATH_INFO"]
        Profiler.configuration.skip_paths.none? { |pattern| path =~ pattern }
      end

      def build_request(env)
        if defined?(ActionDispatch::Request)
          ActionDispatch::Request.new(env)
        else
          Rack::Request.new(env)
        end
      end

      # Builds the collectors without subscribing them: Lifecycle.subscribe_all does, so that
      # a failure part way leaves every collector reachable for release.
      def create_collectors(profile)
        Profiler.configuration.collectors.map { |collector_class| collector_class.new(profile) }
      end

      def html_response?(headers)
        content_type = headers["Content-Type"]
        content_type && content_type.include?("text/html")
      end

      def read_rack_input(env)
        input = env["rack.input"]
        return "" unless input

        input.rewind
        content = input.read
        input.rewind
        content
      rescue
        ""
      end

      def collect_body(body)
        parts = []
        body.each { |part| parts << part }
        body.close if body.respond_to?(:close)
        parts.join
      rescue
        ""
      end

      def current_memory
        return 0 unless defined?(GC.stat)

        stats = GC.stat
        if stats.key?(:total_allocated_size)
          stats[:total_allocated_size]
        elsif stats.key?(:total_allocated_objects)
          stats[:total_allocated_objects] * 40
        else
          0
        end
      end
    end
  end
end
