# frozen_string_literal: true

require_relative "../models/profile"
require_relative "../current_context"
require_relative "toolbar_injector"

module Profiler
  module Middleware
    class ProfilerMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless should_profile?(env)

        status = nil
        headers = nil
        body = nil
        collectors = nil

        profile = Models::Profile.new(build_request(env))
        profile.gem_version = Profiler::VERSION
        Profiler::CurrentContext.token = profile.token

        # Capture request body before app processes it
        req_body_raw = read_rack_input(env)

        # Store profile in env for collectors
        env["profiler.profile"] = profile

        collectors = create_collectors(profile)
        env["profiler.collectors"] = collectors

        # Measure memory before
        memory_before = current_memory if Profiler.configuration.track_memory

        status, headers, body = @app.call(env)

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

        collectors.each do |collector|
          begin
            collector.collect if collector.respond_to?(:collect)
            profile.add_collector_metadata(collector)
          rescue => e
            warn "Collector #{collector.class} failed: #{e.message}"
          end
        end

        Profiler.storage.save(profile.token, profile)
        Profiler::CurrentContext.clear

        headers["X-Profiler-Token"] = profile.token

        if html_response?(headers)
          nonce = env['action_dispatch.content_security_policy_nonce']
          body = ToolbarInjector.new(body, profile.token, nonce).inject
        end

        [status, headers, body]
      rescue => e
        warn "Profiler error: #{e.message}\n#{e.backtrace.join("\n")}"
        collectors&.each { |c| c.unsubscribe if c.respond_to?(:unsubscribe) }
        Profiler::CurrentContext.clear
        status ? [status, headers, body || []] : @app.call(env)
      end

      private

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

      def create_collectors(profile)
        Profiler.configuration.collectors.map do |collector_class|
          collector = collector_class.new(profile)
          collector.subscribe if collector.respond_to?(:subscribe)
          collector
        end
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
