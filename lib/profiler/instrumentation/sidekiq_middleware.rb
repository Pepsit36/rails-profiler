# frozen_string_literal: true

module Profiler
  module Instrumentation
    class SidekiqMiddleware
      def call(worker, job, queue, &block)
        Profiler::JobProfiler.profile(
          job_class: job["class"],
          job_id: job["jid"],
          queue: queue,
          arguments: job["args"],
          executions: job["retry_count"].to_i,
          &block
        )
      end
    end
  end
end
