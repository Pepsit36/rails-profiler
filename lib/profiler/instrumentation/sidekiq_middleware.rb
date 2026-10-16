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
        Profiler.env_override_store.apply!
        # A job run through the ActiveJob adapter reaches Sidekiq wrapped (job["wrapped"] names the
        # real class) and is profiled by ActiveJobInstrumentation's around_perform: profiling the
        # wrapper too would record the same work twice.
        return block.call if job["wrapped"] && active_job_profiled?

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

      private

      def active_job_profiled?
        defined?(ActiveJob::Base) && defined?(Profiler::Instrumentation::ActiveJobInstrumentation) &&
          ActiveJob::Base.include?(Profiler::Instrumentation::ActiveJobInstrumentation)
      end
    end
  end
end
