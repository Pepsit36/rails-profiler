# frozen_string_literal: true

require "rails/railtie"

module Profiler
  class Railtie < Rails::Railtie
    config.profiler = ActiveSupport::OrderedOptions.new

    # Runs before the application's config/initializers, so that they override what it sets.
    # The Rails defaults go only where config/application.rb, which runs earlier still, has not
    # assigned the option, and config.profiler, also set there, is applied on top.
    initializer "profiler.set_configs" do |app|
      development_or_test = Rails.env.development? || Rails.env.test?
      Profiler.configure do |config|
        config.default(:enabled, development_or_test)
        config.default(:storage, development_or_test ? :file : :memory)
        config.default(:track_tests, Rails.env.test?)

        app.config.profiler.each do |key, value|
          if config.respond_to?("#{key}=")
            config.public_send("#{key}=", value)
          else
            Rails.logger&.warn("[Profiler] config.profiler.#{key} is not a profiler option, ignored")
          end
        end
      end
    end

    # Always inserted here, before the application's initializers have decided `enabled`, so
    # that the profiler keeps its place in the stack relative to the middlewares they insert;
    # profiler.remove_disabled_middleware takes it out again once they have run.
    initializer "profiler.insert_middleware", before: :build_middleware_stack do |app|
      require_relative "middleware/profiler_middleware"

      # It sets the framing headers of every profiler response, and its CORS headers only
      # when extension_cors_enabled is set.
      require_relative "middleware/cors_middleware"
      app.middleware.insert_before 0, Profiler::Middleware::CorsMiddleware

      app.middleware.insert_before 0, Profiler::Middleware::ProfilerMiddleware
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

    # Everything below runs after the application's config/initializers, where `enabled` is
    # decided, and before the middleware stack is built. An initializer declared without
    # `after:` runs after the one declared before it, so these stay declared last, in order.
    initializer "profiler.remove_disabled_middleware", after: :load_config_initializers do |app|
      next if Profiler.configuration.enabled

      # Rails applies every delete after the other middleware operations, whatever their order.
      app.middleware.delete Profiler::Middleware::ProfilerMiddleware
      app.middleware.delete Profiler::Middleware::CorsMiddleware
    end

    initializer "profiler.setup_test_profiler" do
      next unless Profiler.configuration.enabled && Profiler.configuration.track_tests

      require_relative "test_profiler"
      require_relative "test_helpers/rspec_support"
      require_relative "test_helpers/minitest_support"
      require_relative "test_runner/discovery"
      require_relative "test_runner/run_store"
      require_relative "test_runner/runner"
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

    initializer "profiler.start_cluster_client" do
      # Check slave? inside on_load — the app's own initializers (config/initializers/profiler.rb)
      # set master_url AFTER railtie initializers run, so the check must happen after_initialize.
      ActiveSupport.on_load(:after_initialize) do
        next unless Profiler.configuration.enabled

        require_relative "cluster/security"
        Profiler::Cluster::Security.warn_about_configuration(Rails.logger)
        next unless Profiler.configuration.slave?

        require_relative "cluster/master_client"
        Profiler::Cluster::MasterClient.new.start
      end
    end

    # After the application's config/initializers, so that `enabled` is the application's own.
    # Declared last: an initializer without `after:` runs after the one declared before it, so
    # one declared below this one would move past the application's initializers too.
    initializer "profiler.apply_env_overrides", after: :load_config_initializers do
      Profiler.env_override_store.apply_at_boot!(Rails.logger)
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
