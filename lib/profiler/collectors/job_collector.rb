# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class JobCollector < BaseCollector
      def initialize(profile, job_data = {})
        super(profile)
        @job_data = job_data.merge(status: "running")
      end

      def icon
        "⚙️"
      end

      def priority
        5
      end

      def tab_config
        {
          key: "job",
          label: "Job",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: true
        }
      end

      def update_status(status, error_message = nil)
        @job_data[:status] = status
        @job_data[:error] = error_message if error_message
      end

      def collect
        store_data(@job_data)
      end

      def has_data?
        @job_data.key?(:job_class)
      end

      def toolbar_summary
        { text: @job_data[:job_class].to_s, color: @job_data[:status] == "failed" ? "red" : "green" }
      end
    end
  end
end
