# frozen_string_literal: true

require_relative "profiler/version"
require_relative "profiler/configuration"

module Profiler
  class Error < StandardError; end

  class << self
    attr_writer :configuration

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def storage
      @storage ||= configuration.storage_backend
    end

    def enabled?
      configuration.enabled
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
end

# Require core components
require_relative "profiler/collectors/base_collector"
require_relative "profiler/collectors/request_collector"
require_relative "profiler/collectors/database_collector"
require_relative "profiler/collectors/ajax_collector"
require_relative "profiler/collectors/performance_collector"
require_relative "profiler/collectors/view_collector"
require_relative "profiler/collectors/cache_collector"
require_relative "profiler/collectors/dump_collector"

require_relative "profiler/railtie" if defined?(Rails::Railtie)
require_relative "profiler/engine" if defined?(Rails::Engine)
