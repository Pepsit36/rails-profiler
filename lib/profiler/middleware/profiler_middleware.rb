# frozen_string_literal: true

require "rack"
require_relative "../models/profile"
require_relative "../current_context"
require_relative "../collectors/lifecycle"
require_relative "toolbar_injector"
require_relative "capturing_body"
require_relative "streamed_profile"

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

        # A stream this thread left open, and any held for too long, release what they hold.
        StreamedProfile.sweep

        collectors = nil
        kept = nil
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

          response, kept = complete_profile(env, profile, collectors, request_body, allocations_before, response)
          response
        ensure
          # Opened before the first subscribe: whatever happens from there on, an exception
          # outside StandardError included, nothing a collector installed outlives the request.
          # The collectors kept for a streamed body only give their thread-local slots back
          # here; StreamedProfile releases the rest.
          release(collectors, kept)
        end
      end

      private

      def complete_profile(env, profile, collectors, request_body, allocations_before, response)
        status, headers, body = response

        if Profiler.configuration.track_memory
          profile.allocated_objects = AllocationCounter.current - allocations_before
        end

        unless buffered_body?(headers, body)
          return stream_through(env, profile, collectors, request_body, allocations_before, response)
        end

        begin
          content = read_buffered_body(body)
        rescue Exception => e # rubocop:disable Lint/RescueException
          # Raised while the body was read: the server answers it, as it would without the profiler.
          record_failed_request(env, profile, collectors, request_body, allocations_before, e) if failed_request?(e)
          raise
        end

        [complete_buffered(env, profile, collectors, request_body, status, headers, content), nil]
      end

      # The whole body is in memory already: profiled at once, and the toolbar goes into a page.
      def complete_buffered(env, profile, collectors, request_body, status, headers, content)
        body = [content]
        headers = headers.dup

        record_response(env, profile, request_body, status, headers, content, content.bytesize, true)
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

      # A stream leaves at once, chunk by chunk, and its profile is saved when the server closes
      # the body. The collectors that read the request's thread are collected now, on it; the
      # others stay subscribed until then (StreamedProfile), so that what the stream does is
      # recorded. Returns the response and the collectors kept.
      def stream_through(env, profile, collectors, request_body, allocations_before, response)
        status, headers, body = response
        profiled_headers = headers.dup
        headers = headers.dup

        profile.finish(status, profiled_headers)
        kept, now = collectors.partition { |collector| collect_from_any_thread?(collector) }
        collect_all(profile, now)
        # Their tabs keep their place; what they hold is filled in when they are collected.
        kept.each { |collector| profile.add_collector_metadata(collector) }
        set_header(headers, TOKEN_HEADER, profile.token)

        # A Rack 3 streaming body (call without each) writes to the socket itself: nothing to relay.
        unless body.respond_to?(:each)
          kept.each do |collector|
            collector.collect if collector.respond_to?(:collect)
            profile.refresh_collector_metadata(collector)
          rescue => e
            warn "Collector #{collector.class} failed: #{e.message}"
          end
          record_response(env, profile, request_body, status, profiled_headers, "", nil, false)
          Profiler.storage.save(profile.token, profile)
          return [[status, headers, body], nil]
        end

        streamed = StreamedProfile.new(profile, kept) do |captured, size, complete, error|
          finish_streamed(env, streamed, collectors, request_body, allocations_before, status, profiled_headers,
                          captured, size, complete, error)
        end
        limit = Profiler.configuration.max_captured_body_bytes
        streamed.body = CapturingBody.new(body, limit: limit, context: streamed) do |captured, size, complete, error|
          streamed.finish(captured, size, complete, error)
        end
        StreamedProfile.register(streamed)
        [[status, headers, streamed.body], kept]
      rescue => e
        warn "Profiler error: #{e.message}\n#{e.backtrace.join("\n")}"
        [[status, headers, body], nil]
      end

      def finish_streamed(env, streamed, collectors, request_body, allocations_before, status, headers,
                          captured, size, complete, error)
        profile = streamed.profile
        if Profiler.configuration.track_memory
          profile.allocated_objects = AllocationCounter.current - allocations_before
        end
        collectors.each { |collector| collector.capture(error) if collector.respond_to?(:capture) } if error
        streamed.release_collectors
        record_response(env, profile, request_body, status, headers, captured, size, complete)

        # Collected again: the request collector, which reads the profile, and a collector
        # collected when the application returned that has an error to add.
        collectors.each do |collector|
          next unless collector.is_a?(Collectors::RequestCollector) ||
                      (error && collector.respond_to?(:capture) && !collect_from_any_thread?(collector))

          collector.collect
          profile.refresh_collector_metadata(collector)
        rescue => e
          warn "Collector #{collector.class} failed: #{e.message}"
        end

        Profiler.storage.save(profile.token, profile)
      rescue => e
        warn "Profiler error while finishing a streamed response: #{e.message}"
      end

      def collect_from_any_thread?(collector)
        collector.respond_to?(:collect_from_any_thread?) && collector.collect_from_any_thread?
      end

      # +complete+: whether +size+ is the whole body's, or only what was seen before it stopped.
      def record_response(env, profile, request_body, status, headers, content, size, complete)
        limit = Profiler.configuration.max_captured_body_bytes
        content = Redaction.cut_bytes(content, limit) if limit

        profile.finish(status, headers)
        profile.set_bodies(
          request_body: request_body[:content],
          request_body_size: request_body[:size],
          request_body_size_is_minimum: request_body[:size_is_minimum],
          response_body: content,
          response_body_size: size,
          response_body_size_is_minimum: !complete,
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

      def release(collectors, kept = nil)
        Collectors::Lifecycle.release_all(kept ? collectors - kept : collectors)
        kept&.each do |collector|
          collector.release_thread_slots if collector.respond_to?(:release_thread_slots)
        rescue => e
          warn "Profiler: Collector #{collector.class} release failed: #{e.message}"
        end
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
      # A body already framed for the wire (Transfer-Encoding: chunked, as Rails 7.0 streams a
      # template) is never read either: a toolbar put into it would break the framing.
      def buffered_body?(headers, body)
        return false if body.respond_to?(:to_path)
        return false if content_type(headers).include?("text/event-stream")
        return false if header(headers, "transfer-encoding")

        body.respond_to?(:to_ary) || buffered_rails_body?(body)
      end

      # Rails' own body, read whole when it is in memory although it has no to_ary:
      # - Rails 7.0, whose RackBody has no to_ary at all: without this, a page that sets its own
      #   ETag, which Rack::ETag then leaves alone, would lose the toolbar;
      # - a controller that includes ActionController::Live answers every action through a
      #   Live::Buffer, a queue fed by the action's thread with no to_ary: when the action
      #   rendered its page whole, the buffer is already closed when the application returns,
      #   and reading it does not wait. One still open is a stream.
      # A sent file (FileBody) is a stream. This reads Rails' internals: RackBody keeps its
      # response in @response, and Response::Buffer answers closed?, in Rails 7.0, 7.1, 7.2, 8.0
      # and 8.1 (checked in their sources); spec/middleware/rails_body_internals_spec.rb fails
      # if that changes.
      def buffered_rails_body?(body)
        return false unless defined?(ActionDispatch::Response::RackBody)

        body = body.instance_variable_get(:@body) while body.is_a?(Rack::BodyProxy)
        return false unless body.is_a?(ActionDispatch::Response::RackBody)

        stream = body.instance_variable_get(:@response)&.stream
        return true if stream.instance_of?(ActionDispatch::Response::Buffer)

        defined?(ActionController::Live::Buffer) && stream.instance_of?(ActionController::Live::Buffer) && stream.closed?
      end

      # No rescue: an error raised by the body is the application's, for the server to answer.
      # Rack 3 has to_ary close the body, Rails' own body and Rack 2 do not: closed here unless
      # it says it is. An error from close does not hide one raised while reading.
      def read_buffered_body(body)
        content =
          begin
            if body.respond_to?(:to_ary)
              body.to_ary.join
            else
              parts = +""
              body.each { |part| parts << part }
              parts
            end
          rescue Exception # rubocop:disable Lint/RescueException
            begin
              close_body(body)
            rescue => e
              warn "Profiler: closing a body that failed also failed: #{e.message}"
            end
            raise
          end
        close_body(body)
        content
      end

      def close_body(body)
        body.close if body.respond_to?(:close) && !(body.respond_to?(:closed?) && body.closed?)
      end

      # At most max_captured_body_bytes of rack.input, given back rewound to the application.
      # An input that cannot be rewound is not read at all: the application would lose it.
      def read_request_body(env)
        input = env["rack.input"]
        return { content: "", size: nil } unless input.respond_to?(:rewind)

        limit = Profiler.configuration.max_captured_body_bytes
        begin
          input.rewind
          content = (limit ? input.read(limit + 1) : input.read).to_s
        ensure
          input.rewind
        end

        declared = env["CONTENT_LENGTH"].to_s
        known = declared.match?(/\A\d+\z/)
        # Without a Content-Length, the size of a cut body is only known to exceed the limit.
        size = known ? declared.to_i : content.bytesize
        size_is_minimum = !known && limit && content.bytesize > limit
        content = Redaction.cut_bytes(content, limit) if limit
        { content: content, size: size, size_is_minimum: size_is_minimum || false }
      rescue => e
        warn "Profiler: could not read the request body: #{e.message}"
        { content: "", size: nil }
      end
    end
  end
end
