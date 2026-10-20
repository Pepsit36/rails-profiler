# frozen_string_literal: true

module Profiler
  module Alerts
    # One thread, one bounded queue. Every check (the detections, the hook, the webhook) runs here,
    # one after the other, so a slow or unreachable webhook never piles up threads: when the queue
    # is full the job is dropped and logged. The thread is started on first use, with
    # RequestContext.detached so it holds nothing of the request that started it, and started
    # again when it is gone (a fork does not carry threads over).
    class Worker
      CAPACITY = 100

      def initialize(capacity: CAPACITY)
        @queue = SizedQueue.new(capacity)
        @lock = Mutex.new
        @idle = ConditionVariable.new
        @pending = 0
        @thread = nil
        @pid = Process.pid
      end

      # True when queued, false when the queue is full.
      def push(&job)
        ensure_thread
        @lock.synchronize { @pending += 1 }
        @queue.push(job, true)
        true
      rescue ThreadError
        @lock.synchronize { @pending -= 1 }
        false
      end

      # Waits until every job queued so far is done. For tests and for shutdown.
      def drain(timeout = 10)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        @lock.synchronize do
          while @pending.positive?
            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return false unless left.positive?

            @idle.wait(@lock, left)
          end
        end
        true
      end

      private

      def ensure_thread
        @lock.synchronize do
          reset_after_fork
          return if @thread&.alive?

          @thread = Instrumentation::RequestContext.detached { Thread.new { work } }
        end
      end

      def reset_after_fork
        return if @pid == Process.pid

        @pid = Process.pid
        @queue = SizedQueue.new(@queue.max)
        @pending = 0
        @thread = nil
      end

      def work
        loop do
          job = @queue.pop
          begin
            job.call
          rescue StandardError => e
            Profiler.log_error("Alerts: a check failed", e)
          ensure
            @lock.synchronize do
              @pending -= 1
              @idle.broadcast if @pending <= 0
            end
          end
        end
      end
    end
  end
end
