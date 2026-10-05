# frozen_string_literal: true

require "rack"
require_relative "../models/profile"
require_relative "../current_context"
require_relative "../collectors/lifecycle"
require_relative "toolbar_injector"
require_relative "capturing_body"

module Profiler
  module Middleware
    class ProfilerMiddleware
      # Rack 3 wants header names in lower case; Rack::Headers takes either.
      TOKEN_HEADER = defined?(Rack::Headers) ? "x-profiler-token" : "X-Profiler-Token"

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
            request_body = read_request_body(env)

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

          allocations_before = AllocationCounter.current if Profiler.configuration.track_memory

          begin
            response = @app.call(env)
          rescue Exception => e # rubocop:disable Lint/RescueException
            record_failed_request(env, profile, collectors, request_body, allocations_before, e) if failed_request?(e)
            raise
          end

          complete_profile(env, profile, collectors, request_body, allocations_before, response)
        ensure
          # Opened before the first subscribe: whatever happens from there on, an exception
          # outside StandardError included, nothing a collector installed outlives the request.
          # A streamed body is finished later, when the server closes it, but its collectors
          # are released here all the same: they read and restore this thread's state.
          release(collectors)
        end
      end

      private

      def complete_profile(env, profile, collectors, request_body, allocations_before, response)
        status, headers, body = response

        if Profiler.configuration.track_memory
          profile.allocated_objects = AllocationCounter.current - allocations_before
        end

        return stream_through(env, profile, collectors, request_body, response) unless buffered_body?(headers, body)

        begin
          content = read_buffered_body(body)
        rescue Exception => e # rubocop:disable Lint/RescueException
          # Raised while the body was read: the server answers it, as it would without the profiler.
          record_failed_request(env, profile, collectors, request_body, allocations_before, e) if failed_request?(e)
          raise
        end

        complete_buffered(env, profile, collectors, request_body, status, headers, content)
      end

      # The whole body is in memory already: profiled at once, and the toolbar goes into a page.
      def complete_buffered(env, profile, collectors, request_body, status, headers, content)
        body = [content]
        headers = headers.dup

        record_response(env, profile, request_body, status, headers, content, content.bytesize)
        collect_all(profile, collectors)

        Profiler.storage.save(profile.token, profile)

        set_header(headers, TOKEN_HEADER, profile.token)

        if html_response?(headers)
          nonce = env['action_dispatch.content_security_policy_nonce']
          injected = ToolbarInjector.new(body, profile.token, nonce).inject
          # A HEAD answer, or a page without </body>, keeps the length it announced.
          update_content_length(headers, injected) unless injected.equal?(body)
          body = injected
        end

        [status, headers, body]
      rescue => e
        # The application has run: its response goes out, profiled or not.
        warn "Profiler error: #{e.message}\n#{e.backtrace.join("\n")}"
        [status, headers, body || []]
      end

      # A stream leaves at once, chunk by chunk. The collectors are read now, on the request's
      # thread; the body, the duration and an error raised while streaming are added when the
      # server closes the body, and the profile is saved then.
      def stream_through(env, profile, collectors, request_body, response)
        status, headers, body = response
        profiled_headers = headers.dup
        headers = headers.dup

        profile.finish(status, profiled_headers)
        collect_all(profile, collectors)
        set_header(headers, TOKEN_HEADER, profile.token)

        # A Rack 3 streaming body (call without each) writes to the socket itself: nothing to relay.
        unless body.respond_to?(:each)
          record_response(env, profile, request_body, status, profiled_headers, "", nil)
          Profiler.storage.save(profile.token, profile)
          return [status, headers, body]
        end

        limit = Profiler.configuration.max_captured_body_bytes
        streamed = CapturingBody.new(body, limit: limit) do |captured, size, error|
          finish_streamed(env, profile, collectors, request_body, status, profiled_headers, captured, size, error)
        end
        [status, headers, streamed]
      rescue => e
        warn "Profiler error: #{e.message}\n#{e.backtrace.join("\n")}"
        [status, headers, body]
      end

      def finish_streamed(env, profile, collectors, request_body, status, headers, captured, size, error)
        record_response(env, profile, request_body, status, headers, captured, size)

        # Only the collectors that read the profile, or the error, collect again: the others
        # were read and released on the request's thread.
        collectors.each do |collector|
          if error && collector.respond_to?(:capture)
            collector.capture(error)
          elsif !collector.is_a?(Collectors::RequestCollector)
            next
          end
          collector.collect
          profile.refresh_collector_metadata(collector)
        rescue => e
          warn "Collector #{collector.class} failed: #{e.message}"
        end

        Profiler.storage.save(profile.token, profile)
      rescue => e
        warn "Profiler error while finishing a streamed response: #{e.message}"
      end

      def record_response(env, profile, request_body, status, headers, content, size)
        limit = Profiler.configuration.max_captured_body_bytes
        content = Redaction.cut_bytes(content, limit) if limit

        profile.finish(status, headers)
        profile.set_bodies(
          request_body: request_body[:content],
          request_body_size: request_body[:size],
          response_body: content,
          response_body_size: size,
          req_content_type: env["CONTENT_TYPE"].to_s,
          resp_content_type: content_type(headers)
        )
      end

      # A request cut short by a timeout (Timeout::ExitException, Rack::Timeout) is profiled like
      # one that raised; one stopped by a signal or an exit is not, the process is going away.
      def failed_request?(error)
        !error.is_a?(SignalException) && !error.is_a?(SystemExit)
      end

      # The profile of a request that raised is kept: status 500, which the server answers once
      # the exception leaves the stack, and the exception itself. Never masks the exception.
      def record_failed_request(env, profile, collectors, request_body, allocations_before, error)
        collectors.each { |collector| collector.capture(error) if collector.respond_to?(:capture) }
        if Profiler.configuration.track_memory
          profile.allocated_objects = AllocationCounter.current - allocations_before
        end
        profile.finish(500)
        profile.set_bodies(
          request_body: request_body[:content],
          request_body_size: request_body[:size],
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
        content_type(headers).include?("text/html")
      end

      def content_type(headers)
        header(headers, "content-type").to_s
      end

      # Response headers come as a Rack::Headers (any case), or as a plain Hash whose names are
      # lower case under Rack 3 and of any case under Rack 2: every read and write here ignores
      # the case.
      def header(headers, name)
        return headers[name] if defined?(Rack::Headers) && headers.is_a?(Rack::Headers)

        headers.each { |key, value| return value if key.to_s.casecmp?(name) }
        nil
      end

      # Keeps the spelling of a name the application already used, for a Rack 2 middleware
      # above that looks it up as written.
      def set_header(headers, name, value)
        existing = headers.keys.select { |key| key.to_s.casecmp?(name) }
        existing.each { |key| headers.delete(key) }
        headers[existing.first || name] = value
      end

      # Only a length the application announced is corrected: a chunked or unsized answer
      # stays without one.
      def update_content_length(headers, body)
        return if header(headers, "content-length").nil?

        set_header(headers, "content-length", body.sum(&:bytesize).to_s)
      end

      # Read whole only when it is already in memory: a body that answers to_ary (Rack 3 lets a
      # middleware call it), or the buffered body of Rails 7.0, which has no to_ary. A file sent
      # by its path and an event stream are never read, even when they could be.
      def buffered_body?(headers, body)
        return false if body.respond_to?(:to_path)
        return false if content_type(headers).include?("text/event-stream")

        body.respond_to?(:to_ary) || buffered_rails_body?(body)
      end

      # Rails 7.0: without this, a page that sets its own ETag, which Rack::ETag then leaves
      # alone, would lose the toolbar. A Live response feeds a queue from the action's thread,
      # and a sent file is a FileBody: both are streams.
      def buffered_rails_body?(body)
        return false unless defined?(ActionDispatch::Response::RackBody)

        body = body.instance_variable_get(:@body) while body.is_a?(Rack::BodyProxy)
        return false unless body.is_a?(ActionDispatch::Response::RackBody)

        body.instance_variable_get(:@response)&.stream.instance_of?(ActionDispatch::Response::Buffer)
      end

      # No rescue: an error raised by the body is the application's, for the server to answer.
      def read_buffered_body(body)
        if body.respond_to?(:to_ary)
          body.to_ary.join
        else
          content = +""
          body.each { |part| content << part }
          content
        end
      ensure
        # Rack 3 has to_ary close the body, Rails' own body and Rack 2 do not.
        body.close if body.respond_to?(:close) && !(body.respond_to?(:closed?) && body.closed?)
      end

      # At most max_captured_body_bytes of rack.input, given back rewound to the application.
      # An input that cannot be rewound is not read at all: the application would lose it.
      def read_request_body(env)
        input = env["rack.input"]
        return { content: "", size: nil } unless input.respond_to?(:rewind)

        limit = Profiler.configuration.max_captured_body_bytes
        input.rewind
        content = (limit ? input.read(limit + 1) : input.read).to_s
        input.rewind

        declared = env["CONTENT_LENGTH"].to_s
        # Without a Content-Length, the size of a cut body is only known to exceed the limit.
        size = declared.match?(/\A\d+\z/) ? declared.to_i : content.bytesize
        content = Redaction.cut_bytes(content, limit) if limit
        { content: content, size: size }
      rescue => e
        warn "Profiler: could not read the request body: #{e.message}"
        { content: "", size: nil }
      end
    end
  end
end
