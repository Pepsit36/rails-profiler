# frozen_string_literal: true

module Profiler
  module Instrumentation
    class SidekiqClientMiddleware
      def call(_worker_class, job, _queue, _redis_pool)
        job["profiler_parent_token"] = Profiler::CurrentContext.token
        yield
      end
    end

    class SidekiqMiddleware
      def call(worker, job, queue, &block)
        Profiler::JobProfiler.profile(
          job_class: job["class"],
          job_id: job["jid"],
          queue: queue,
          arguments: job["args"],
          executions: job["retry_count"].to_i,
          parent_token: job["profiler_parent_token"],
          &block
        )
      end
    end
  end
end
