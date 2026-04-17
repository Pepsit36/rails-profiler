# frozen_string_literal: true

require_relative "models/profile"
require_relative "current_context"
require_relative "collectors/test_collector"
require_relative "collectors/database_collector"
require_relative "collectors/cache_collector"
require_relative "collectors/exception_collector"
require_relative "collectors/env_collector"
require_relative "collectors/flamegraph_collector"

module Profiler
  class TestProfiler
    TEST_COLLECTOR_CLASSES = [
      Collectors::DatabaseCollector,
      Collectors::CacheCollector,
      Collectors::ExceptionCollector,
      Collectors::EnvCollector,
      Collectors::FlameGraphCollector
    ].freeze

    def self.profile(test_name:, test_file:, test_line:, framework:, &block)
      return block.call unless Profiler.enabled?

      new(
        test_name: test_name,
        test_file: test_file,
        test_line: test_line,
        framework: framework
      ).run(&block)
    end

    def initialize(test_name:, test_file:, test_line:, framework:)
      @test_name = test_name
      @test_file = test_file
      @test_line = test_line
      @framework = framework
    end

    def run(&block)
      profile = Models::Profile.new
      profile.profile_type = "test"
      profile.path = @test_file
      profile.method = "TEST"

      test_collector = Collectors::TestCollector.new(
        profile,
        test_name: @test_name,
        test_file: @test_file,
        test_line: @test_line,
        framework: @framework
      )

      collectors = [test_collector] + TEST_COLLECTOR_CLASSES.map { |klass| klass.new(profile) }
      collectors.each { |c| c.subscribe if c.respond_to?(:subscribe) }

      exception_collector = collectors.find { |c| c.is_a?(Collectors::ExceptionCollector) }

      memory_before = current_memory if Profiler.configuration.track_memory

      test_status = "passed"
      error_message = nil

      previous_token = Profiler::CurrentContext.token
      Profiler::CurrentContext.token = profile.token

      begin
        result = block.call
        result
      rescue Exception => e # rubocop:disable Lint/RescueException
        # Capture all exceptions (including test failures which may subclass Exception)
        test_status = "failed"
        error_message = "#{e.class}: #{e.message}"
        exception_collector&.capture(e) if e.is_a?(StandardError)
        raise
      ensure
        Profiler::CurrentContext.token = previous_token

        if Profiler.configuration.track_memory
          profile.memory = current_memory - memory_before
        end

        test_collector.update_status(test_status, error_message)
        profile.finish(test_status == "passed" ? 200 : 500)

        collectors.each do |collector|
          begin
            collector.collect if collector.respond_to?(:collect)
            profile.add_collector_metadata(collector)
          rescue => e
            warn "Profiler TestProfiler: Collector #{collector.class} failed: #{e.message}"
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
