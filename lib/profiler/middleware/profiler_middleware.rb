# frozen_string_literal: true

require_relative "../models/profile"
require_relative "toolbar_injector"

module Profiler
  module Middleware
    class ProfilerMiddleware
      def initialize(app)
        @app = app
      end

      def call(env)
        return @app.call(env) unless should_profile?(env)

        profile = Models::Profile.new(build_request(env))

        # Store profile in env for collectors
        env["profiler.profile"] = profile

        # Create and subscribe collectors
        collectors = create_collectors(profile)
        env["profiler.collectors"] = collectors

        # Measure memory before
        memory_before = current_memory if Profiler.configuration.track_memory

        # Process request
        status, headers, body = @app.call(env)

        # Measure memory after
        if Profiler.configuration.track_memory
          memory_after = current_memory
          profile.memory = memory_after - memory_before
        end

        # Finish profile
        profile.finish(status, headers)

        # Collect data from all collectors
        collectors.each do |collector|
          begin
            collector.collect if collector.respond_to?(:collect)
            profile.add_collector_metadata(collector)
          rescue => e
            warn "Collector #{collector.class} failed: #{e.message}"
          end
        end

        # Store profile
        Profiler.storage.save(profile.token, profile)

        # Add profiler token header
        headers["X-Profiler-Token"] = profile.token

        # Inject toolbar if HTML response
        if html_response?(headers)
          body = ToolbarInjector.new(body, profile.token).inject
        end

        [status, headers, body]
      rescue => e
        warn "Profiler error: #{e.message}\n#{e.backtrace.join("\n")}"
        @app.call(env)
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

      def current_memory
        if defined?(GC.stat)
          GC.stat(:total_allocated_objects) * 40 # Rough estimate
        else
          0
        end
      end
    end
  end
end
