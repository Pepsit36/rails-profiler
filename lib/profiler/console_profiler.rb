# frozen_string_literal: true

require_relative "models/profile"
require_relative "current_context"
require_relative "collectors/console_collector"
require_relative "collectors/database_collector"
require_relative "collectors/cache_collector"
require_relative "collectors/http_collector"
require_relative "collectors/dump_collector"
require_relative "collectors/log_collector"
require_relative "collectors/exception_collector"
require_relative "collectors/env_collector"
require_relative "collectors/flamegraph_collector"

module Profiler
  class ConsoleProfiler
    CONSOLE_COLLECTOR_CLASSES = [
      Collectors::DatabaseCollector,
      Collectors::CacheCollector,
      Collectors::HttpCollector,
      Collectors::DumpCollector,
      Collectors::LogCollector,
      Collectors::ExceptionCollector,
      Collectors::EnvCollector,
      Collectors::FlameGraphCollector
    ].freeze

    RECORDING_KEY = :profiler_console_recording

    SOURCES = %w[console runner].freeze

    # source is "console" for an expression typed in IRB or Pry, "runner" for a
    # `rails runner` execution; each has its own track_* option.
    def self.profile(expression:, source: "console", &block)
      return block.call unless Profiler.enabled? && tracked?(source)

      # IRB and Pry can both be loaded and both evaluate the same expression: only the
      # outermost one records it.
      return block.call if Thread.current[RECORDING_KEY]

      begin
        Thread.current[RECORDING_KEY] = true
        new(expression: expression, source: source).run(&block)
      ensure
        Thread.current[RECORDING_KEY] = nil
      end
    end

    def self.tracked?(source)
      source == "runner" ? Profiler.configuration.track_runner : Profiler.configuration.track_console
    end

    def initialize(expression:, source: "console")
      @expression = expression
      @source = source
    end

    def run(&block)
      profile = Models::Profile.new
      profile.profile_type = "console"
      profile.gem_version = Profiler.version
      profile.path = Redaction.truncate(@expression, 200)
      profile.method = @source == "runner" ? "RUNNER" : "CONSOLE"

      console_collector = Collectors::ConsoleCollector.new(profile, expression: @expression, source: @source)
      collectors = [console_collector] + CONSOLE_COLLECTOR_CLASSES.map { |klass| klass.new(profile) }
      return block.call unless Collectors::Lifecycle.subscribe_all(collectors, "ConsoleProfiler")

      exception_collector = collectors.find { |c| c.is_a?(Collectors::ExceptionCollector) }

      allocations_before = AllocationCounter.current if Profiler.configuration.track_memory

      console_status = "completed"

      previous_token = Profiler::CurrentContext.token
      Profiler::CurrentContext.token = profile.token
      result = nil
      begin
        result = block.call
        console_collector.set_return_value(result)
        result
      rescue Exception => e # rubocop:disable Lint/RescueException
        # `exit` or `exit 0` in a runner script is a normal end, not a failure.
        unless e.is_a?(SystemExit) && e.success?
          console_status = "failed"
          exception_collector&.capture(e)
        end
        raise
      ensure
        Profiler::CurrentContext.token = previous_token
        if Profiler.configuration.track_memory
          profile.allocated_objects = AllocationCounter.current - allocations_before
        end

        profile.finish(console_status == "completed" ? 200 : 500)

        collectors.each do |collector|
          Collectors::Lifecycle.guard(collector, "ConsoleProfiler") do
            collector.collect if collector.respond_to?(:collect)
            profile.add_collector_metadata(collector)
          end
        end

        Profiler.save_profile(profile, from: "ConsoleProfiler")
      end
    ensure
      # After collect, and also when collect or the storage failed.
      Collectors::Lifecycle.release_all(collectors)
    end
  end
end
