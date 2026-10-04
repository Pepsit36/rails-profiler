# frozen_string_literal: true

require_relative "models/profile"
require_relative "current_context"
require_relative "redaction"
require_relative "collectors/job_collector"
require_relative "collectors/database_collector"
require_relative "collectors/cache_collector"
require_relative "collectors/http_collector"
require_relative "collectors/dump_collector"
require_relative "collectors/log_collector"
require_relative "collectors/exception_collector"
require_relative "collectors/env_collector"
require_relative "collectors/flamegraph_collector"
require_relative "collectors/mailer_collector"

module Profiler
  class JobProfiler
    JOB_COLLECTOR_CLASSES = [
      Collectors::DatabaseCollector,
      Collectors::CacheCollector,
      Collectors::HttpCollector,
      Collectors::DumpCollector,
      Collectors::LogCollector,
      Collectors::ExceptionCollector,
      Collectors::EnvCollector,
      Collectors::FlameGraphCollector,
      Collectors::MailerCollector
    ].freeze

    def self.profile(job_class:, job_id:, queue:, arguments:, executions:, parent_token: nil, &block)
      return block.call unless Profiler.enabled? && Profiler.configuration.track_jobs

      new(
        job_class: job_class,
        job_id: job_id,
        queue: queue,
        arguments: arguments,
        executions: executions,
        parent_token: parent_token
      ).run(&block)
    end

    def initialize(job_class:, job_id:, queue:, arguments:, executions:, parent_token: nil)
      @job_class = job_class
      @job_id = job_id
      @queue = queue
      @arguments = arguments
      @executions = executions
      @parent_token = parent_token
    end

    def run(&block)
      profile = Models::Profile.new
      profile.profile_type = "job"
      profile.gem_version = Profiler::VERSION
      profile.path = @job_class
      profile.method = "JOB"
      profile.parent_token = @parent_token if @parent_token

      job_collector = Collectors::JobCollector.new(profile, {
        job_class: @job_class,
        job_id: @job_id,
        queue: @queue,
        arguments: sanitize_arguments(@arguments),
        executions: @executions
      })

      collectors = [job_collector] + JOB_COLLECTOR_CLASSES.map { |klass| klass.new(profile) }
      return block.call unless Collectors::Lifecycle.subscribe_all(collectors, "JobProfiler")

      exception_collector = collectors.find { |c| c.is_a?(Collectors::ExceptionCollector) }

      memory_before = current_memory if Profiler.configuration.track_memory

      job_status = "completed"
      error_message = nil

      previous_token = Profiler::CurrentContext.token
      previous_job_class = Thread.current[:profiler_current_job_class]
      Profiler::CurrentContext.token = profile.token
      Thread.current[:profiler_current_job_class] = @job_class
      begin
        result = block.call
        result
      rescue => e
        job_status = "failed"
        error_message = "#{e.class}: #{e.message}"
        exception_collector&.capture(e)
        raise
      ensure
        Thread.current[:profiler_current_job_class] = previous_job_class
        Profiler::CurrentContext.token = previous_token
        if Profiler.configuration.track_memory
          profile.memory = current_memory - memory_before
        end

        job_collector.update_status(job_status, error_message)
        profile.finish(job_status == "completed" ? 200 : 500)

        collectors.each do |collector|
          begin
            collector.collect if collector.respond_to?(:collect)
            profile.add_collector_metadata(collector)
          rescue => e
            warn "Profiler JobProfiler: Collector #{collector.class} failed: #{e.message}"
          end
        end

        Profiler.storage.save(profile.token, profile)
      end
    ensure
      # After collect, and also when collect or the storage failed.
      Collectors::Lifecycle.release_all(collectors)
    end

    private

    def sanitize_arguments(args)
      return [] unless args

      Redaction.filter_value(args).map do |arg|
        case arg
        when String then Redaction.truncate(arg, 200)
        when Numeric, TrueClass, FalseClass, NilClass then arg
        else
          inspected = arg.inspect
          Redaction.truncate(inspected, 200)
        end
      rescue
        arg.to_s
      end
    end

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
