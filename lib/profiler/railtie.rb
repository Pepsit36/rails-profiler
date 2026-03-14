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
      # Load default collectors
      Profiler.configure do |config|
        config.collectors = [
          Profiler::Collectors::RequestCollector,
          Profiler::Collectors::DumpCollector,
          Profiler::Collectors::DatabaseCollector,
          Profiler::Collectors::PerformanceCollector,
          Profiler::Collectors::ViewCollector,
          Profiler::Collectors::CacheCollector
        ]
      end
    end

    rake_tasks do
      load "profiler/tasks/profiler.rake"
    end
  end
end
