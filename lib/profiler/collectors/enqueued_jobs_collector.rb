# frozen_string_literal: true

require "time"
require_relative "base_collector"

module Profiler
  module Collectors
    # The ActiveJob jobs a request (or a job) puts on a queue. A job only gets a profile of its own
    # once it starts, so until then the profile that enqueued it is the only place that knows it
    # exists. The toolbar route lists those that have not started yet from here.
    class EnqueuedJobsCollector < BaseCollector
      MAX_JOBS = 100

      def initialize(profile)
        super
        @jobs = []
        @subscriptions = []
        @mutex = Mutex.new
      end

      def name
        "enqueued_jobs"
      end

      # Data for the toolbar route and the API only: no tab of its own.
      def tab_config
        { key: name, label: "Enqueued jobs", icon: "", priority: 100, enabled: false, default_active: false }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)
        return unless Profiler.configuration.track_jobs

        # enqueue_at is the event of a job scheduled for later (set(wait:), set(wait_until:)).
        %w[enqueue.active_job enqueue_at.active_job].each do |event|
          @subscriptions << subscribe_notification(event) do |_name, _started, _finished, _id, payload|
            job = payload[:job]
            next if job.nil? || payload[:aborted] || payload[:exception_object]

            record(job)
          end
        end
        # perform_all_later (Rails 7.1+) announces its jobs together, with no event per job.
        @subscriptions << subscribe_notification("enqueue_all.active_job") do |_name, _started, _finished, _id, payload|
          next if payload[:exception_object]

          Array(payload[:jobs]).each { |job| record(job) unless job.respond_to?(:successfully_enqueued?) && !job.successfully_enqueued? }
        end
      end

      # Jobs enqueued from a thread that outlives the request still land here until collect.
      def collect_from_any_thread?
        true
      end

      def unsubscribe
        unsubscribe_notifications(@subscriptions)
      end

      def collect
        unsubscribe
        jobs = @mutex.synchronize { @jobs.map { |entry| entry.transform_keys(&:to_s) } }
        store_data("jobs" => jobs)
      end

      def has_data?
        @mutex.synchronize { @jobs.any? }
      end

      private

      def record(job)
        entry = {
          job_id: job.job_id,
          job_class: job.class.name,
          queue: job.queue_name.to_s,
          enqueued_at: Time.now.utc.iso8601(3),
          scheduled_at: scheduled_at(job)
        }
        @mutex.synchronize { @jobs << entry if @jobs.size < MAX_JOBS }
      rescue StandardError => e
        Profiler.log_error_once(:enqueued_jobs_record, "EnqueuedJobsCollector: could not record an enqueued job", e)
      end

      def scheduled_at(job)
        at = job.respond_to?(:scheduled_at) ? job.scheduled_at : nil
        at = Time.at(at) if at.is_a?(Numeric)
        at&.utc&.iso8601(3)
      end
    end
  end
end
