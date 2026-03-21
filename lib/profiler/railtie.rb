# frozen_string_literal: true

require "rails/railtie"

module Profiler
  class Railtie < Rails::Railtie
    config.profiler = ActiveSupport::OrderedOptions.new

    initializer "profiler.set_configs" do |app|
      # Set default configuration for Rails environment
      Profiler.configure do |config|
        config.enabled = Rails.env.development? || Rails.env.test?
        config.storage = Rails.env.development? ? :file : :memory
        config.storage_options = {
          path: Rails.root.join("tmp", "profiler")
        }
      end
    end

    initializer "profiler.insert_middleware", before: :build_middleware_stack do |app|
      if Profiler.configuration.enabled
        require_relative "middleware/profiler_middleware"

        # Insert CORS middleware first if enabled
        if Profiler.configuration.extension_cors_enabled
          require_relative "middleware/cors_middleware"
          app.middleware.insert_before 0, Profiler::Middleware::CorsMiddleware
        end

        app.middleware.insert_before 0, Profiler::Middleware::ProfilerMiddleware
      end
    end

    initializer "profiler.load_collectors" do
      if Profiler.configuration.collectors.empty?
        Profiler.configure do |config|
          config.collectors = [
            Profiler::Collectors::RequestCollector,
            Profiler::Collectors::DumpCollector,
            Profiler::Collectors::DatabaseCollector,
            Profiler::Collectors::PerformanceCollector,
            Profiler::Collectors::ViewCollector,
            Profiler::Collectors::CacheCollector,
            Profiler::Collectors::HttpCollector,
            Profiler::Collectors::FlameGraphCollector
          ]
        end
      end
    end

    initializer "profiler.setup_job_instrumentation" do
      next unless Profiler.configuration.enabled && Profiler.configuration.track_jobs

      require_relative "job_profiler"

      if defined?(Sidekiq)
        require_relative "instrumentation/sidekiq_middleware"
        Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add Profiler::Instrumentation::SidekiqMiddleware
          end
        end
      end

      if defined?(ActiveJob::Base)
        require_relative "instrumentation/active_job_instrumentation"
        ActiveJob::Base.include Profiler::Instrumentation::ActiveJobInstrumentation
      end
    end

    rake_tasks do
      load "profiler/tasks/profiler.rake"
    end
  end
end
