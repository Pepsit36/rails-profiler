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

    def self.profile(expression:, &block)
      return block.call unless Profiler.enabled? && Profiler.configuration.track_console

      new(expression: expression).run(&block)
    end

    def initialize(expression:)
      @expression = expression
    end

    def run(&block)
      profile = Models::Profile.new
      profile.profile_type = "console"
      profile.gem_version = Profiler::VERSION
      profile.path = @expression.length > 200 ? "#{@expression[0, 200]}..." : @expression
      profile.method = "CONSOLE"

      console_collector = Collectors::ConsoleCollector.new(profile, expression: @expression)
      collectors = [console_collector] + CONSOLE_COLLECTOR_CLASSES.map { |klass| klass.new(profile) }
      collectors.each { |c| c.subscribe if c.respond_to?(:subscribe) }

      exception_collector = collectors.find { |c| c.is_a?(Collectors::ExceptionCollector) }

      memory_before = current_memory if Profiler.configuration.track_memory

      console_status = "completed"

      previous_token = Profiler::CurrentContext.token
      Profiler::CurrentContext.token = profile.token
      result = nil
      begin
        result = block.call
        console_collector.set_return_value(result)
        result
      rescue => e
        console_status = "failed"
        exception_collector&.capture(e)
        raise
      ensure
        Profiler::CurrentContext.token = previous_token
        if Profiler.configuration.track_memory
          profile.memory = current_memory - memory_before
        end

        profile.finish(console_status == "completed" ? 200 : 500)

        collectors.each do |collector|
          begin
            collector.collect if collector.respond_to?(:collect)
            profile.add_collector_metadata(collector)
          rescue => e
            warn "Profiler ConsoleProfiler: Collector #{collector.class} failed: #{e.message}"
          end
        end

        Profiler.storage.save(profile.token, profile)
      end
    end

    private

    def current_memory
      return 0 unless defined?(GC.stat)

      stats = GC.stat
      if stats.key?(:total_allocated_size)
        stats[:total_allocated_size]
      elsif stats.key?(:total_allocated_objects)
        stats[:total_allocated_objects] * 40
      else
        0
      end
    end
  end
end
