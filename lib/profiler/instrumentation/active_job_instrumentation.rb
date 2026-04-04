# frozen_string_literal: true

module Profiler
  module Instrumentation
    module ActiveJobInstrumentation
      extend ActiveSupport::Concern

      included do
        around_perform do |job, block|
          Profiler::JobProfiler.profile(
            job_class: job.class.name,
            job_id: job.job_id,
            queue: job.queue_name,
            arguments: job.arguments,
            executions: job.executions - 1,
            &block
          )
        end
      end
    end
  end
end
