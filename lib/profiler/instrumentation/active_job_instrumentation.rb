# frozen_string_literal: true

module Profiler
  module Instrumentation
    module ActiveJobInstrumentation
      extend ActiveSupport::Concern

      included do
        attr_accessor :profiler_parent_token

        before_enqueue do |job|
          job.profiler_parent_token = Profiler::CurrentContext.token
        end

        around_perform do |job, block|
          Profiler::JobProfiler.profile(
            job_class: job.class.name,
            job_id: job.job_id,
            queue: job.queue_name,
            arguments: job.arguments,
            executions: job.executions - 1,
            parent_token: job.profiler_parent_token,
            &block
          )
        end
      end

      def serialize
        super.merge("profiler_parent_token" => profiler_parent_token)
      end

      def deserialize(job_data)
        super
        self.profiler_parent_token = job_data["profiler_parent_token"]
      end
    end
  end
end
