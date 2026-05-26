# frozen_string_literal: true

require_relative "profiler/version"
require_relative "profiler/configuration"

module Profiler
  class Error < StandardError; end

  class << self
    attr_writer :configuration
    attr_accessor :function_profiling_enabled
    attr_accessor :function_profiling_max_frames
    attr_accessor :function_profiling_mode
    attr_accessor :function_profiling_clock

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def storage
      @storage ||= configuration.storage_backend
    end

    def env_override_store
      @env_override_store ||= EnvOverrideStore.new
    end

    def enabled?
      configuration.enabled
    end

    # Instrument an arbitrary code block and record it in the FlameGraph.
    # Usage: Profiler.measure("payment.stripe_charge", metadata: { amount: 1000 }) { Stripe::Charge.create(...) }
    def measure(label, metadata: {}, &block)
      return yield unless enabled?

      collector = Thread.current[:profiler_flamegraph_collector]
      return yield unless collector

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      collector.record_custom_event(
        label: label,
        started_at: started_at,
        finished_at: finished_at,
        metadata: metadata
      )

      result
    end

    # Dump a variable to the profiler
    # Usage: Profiler.dump(variable, "optional label")
    def dump(value, label = nil)
      return unless enabled?

      # Get caller location
      caller_location = caller_locations(1, 1).first
      file = caller_location.path
      line = caller_location.lineno

      # Initialize dumps array if needed
      Thread.current[:profiler_dumps] ||= []

      # Store the dump
      Thread.current[:profiler_dumps] << {
        value: value,
        label: label,
        file: file,
        line: line,
        timestamp: Time.now
      }

      value
    end
  end

  self.function_profiling_enabled = true
  self.function_profiling_max_frames = 2000
  self.function_profiling_mode = "lite"
  self.function_profiling_clock = "wall"
end

# Require core components
require_relative "profiler/collectors/base_collector"
require_relative "profiler/collectors/request_collector"
require_relative "profiler/collectors/database_collector"
require_relative "profiler/collectors/ajax_collector"
require_relative "profiler/collectors/view_collector"
require_relative "profiler/collectors/cache_collector"
require_relative "profiler/collectors/dump_collector"
require_relative "profiler/collectors/http_collector"
require_relative "profiler/collectors/flamegraph_collector"
require_relative "profiler/collectors/function_profiler_collector"
require_relative "profiler/collectors/log_collector"
require_relative "profiler/collectors/exception_collector"
require_relative "profiler/collectors/routes_collector"
require_relative "profiler/collectors/i18n_collector"
require_relative "profiler/collectors/env_collector"
require_relative "profiler/collectors/mailer_collector"

require_relative "profiler/env_override_store"
require_relative "profiler/instrumentation/thread_context_propagation"
require_relative "profiler/railtie" if defined?(Rails::Railtie)
require_relative "profiler/engine" if defined?(Rails::Engine)
