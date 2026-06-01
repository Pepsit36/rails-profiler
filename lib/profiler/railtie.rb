# frozen_string_literal: true

require "rails/railtie"

module Profiler
  class Railtie < Rails::Railtie
    config.profiler = ActiveSupport::OrderedOptions.new

    initializer "profiler.apply_env_overrides" do
      Profiler.env_override_store.apply!
    end

    initializer "profiler.set_configs" do |app|
      # Set default configuration for Rails environment
      Profiler.configure do |config|
        config.enabled = Rails.env.development? || Rails.env.test?
        config.storage = Rails.env.development? ? :file : :memory
        config.tmp_path = Rails.root.join("tmp", "rails-profiler")
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
            Profiler::Collectors::ExceptionCollector,
            Profiler::Collectors::RequestCollector,
            Profiler::Collectors::DumpCollector,
            Profiler::Collectors::DatabaseCollector,
            Profiler::Collectors::ViewCollector,
            Profiler::Collectors::CacheCollector,
            Profiler::Collectors::HttpCollector,
            Profiler::Collectors::FlameGraphCollector,
            Profiler::Collectors::FunctionProfilerCollector,
            Profiler::Collectors::LogCollector,
            Profiler::Collectors::RoutesCollector,
            Profiler::Collectors::I18nCollector,
            Profiler::Collectors::EnvCollector,
            Profiler::Collectors::MailerCollector
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
        Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add Profiler::Instrumentation::SidekiqClientMiddleware
          end
        end
      end

      if defined?(ActiveJob::Base)
        require_relative "instrumentation/active_job_instrumentation"
        ActiveJob::Base.include Profiler::Instrumentation::ActiveJobInstrumentation
      end
    end

    console do
      next unless Profiler.configuration.enabled && Profiler.configuration.track_console

      require_relative "console_profiler"
      require_relative "instrumentation/irb_instrumentation"
      IRB::Context.prepend(Profiler::Instrumentation::IrbInstrumentation)
    end

    rake_tasks do
      load "profiler/tasks/profiler.rake"
    end
  end
end
