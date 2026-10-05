# frozen_string_literal: true

require_relative "../collectors/lifecycle"
require_relative "../current_context"

module Profiler
  module Middleware
    # The profile of a streamed response between the moment the application returns and the
    # moment the server closes the body. The collectors that read nothing from the request's
    # thread (Collectors::BaseCollector#collect_from_any_thread?) stay subscribed meanwhile, so
    # that the queries, views and logs of the stream are recorded.
    #
    # While the server iterates the body (enter, leave), its fiber carries the profile's token
    # and the thread-local slots of the collectors kept, so that the logs, outbound HTTP calls
    # and measures of the stream are recorded, and a filter by request can tell its events.
    #
    # Rack requires the server to close the body, but nothing here relies on it alone: a
    # stream still open when the execution context that started it (its fiber) starts another
    # profiled request was left behind, and its profile is finished then; one subscribed for
    # longer than MAX_SUBSCRIBED_SECONDS has its collectors released by the next profiled
    # request, from any thread, which the profile says. The body itself is closed only by the
    # server. The context is the fiber, not the thread: a fiber-based server (Falcon) runs
    # many requests at once on one thread, each in its own fiber, and Thread#[] slots are
    # fiber-local too; a threaded server runs each request in its thread's root fiber.
    class StreamedProfile
      MAX_SUBSCRIBED_SECONDS = 300

      @pending = {}
      @lock = Mutex.new

      class << self
        def register(streamed)
          @lock.synchronize { @pending[streamed.object_id] = streamed }
        end

        def unregister(streamed)
          @lock.synchronize { @pending.delete(streamed.object_id) }
        end

        # Run when a profiled request starts.
        def sweep(context = Fiber.current)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          left, old = @lock.synchronize do
            [@pending.values.select { |s| s.context.equal?(context) },
             @pending.values.select { |s| !s.context.equal?(context) && now - s.started_at > MAX_SUBSCRIBED_SECONDS }]
          end
          left.each(&:abandon)
          old.each do |streamed|
            unregister(streamed)
            streamed.release_collectors(after_seconds: MAX_SUBSCRIBED_SECONDS)
          end
        end

        # Releases every stream still subscribed (specs, and a process shutting down).
        def release_all_pending
          @lock.synchronize { @pending.values.tap { @pending.clear } }.each(&:release_collectors)
        end
      end

      attr_reader :profile, :context, :started_at
      attr_accessor :body

      # on_finish runs once, with what the body captured, when it is closed or abandoned.
      def initialize(profile, collectors, &on_finish)
        @profile = profile
        @collectors = collectors
        @on_finish = on_finish
        @context = Fiber.current
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex = Mutex.new
        @released = false
        @finished = false
      end

      # Collects the collectors kept for the stream and releases them, once, from any thread.
      # +after_seconds+: released before the body was closed, after that long; the profile says
      # so, as what came after is missing from it.
      def release_collectors(after_seconds: nil)
        @mutex.synchronize do
          return if @released

          @released = true
          @profile.collectors_released_after_seconds = after_seconds if after_seconds
          @collectors.each do |collector|
            collector.collect if collector.respond_to?(:collect)
            @profile.refresh_collector_metadata(collector)
          rescue => e
            Profiler.log_error("ProfilerMiddleware: collector #{collector.class} failed", e)
          end
          Collectors::Lifecycle.release_all(@collectors)
        end
      end

      def finish(captured, size, complete, error)
        @mutex.synchronize do
          return if @finished

          @finished = true
        end
        self.class.unregister(self)
        @on_finish.call(captured, size, complete, error)
      ensure
        # Whatever on_finish did, nothing stays subscribed.
        release_collectors
      end

      # The server moved on without closing the body: its profile is finished with what it
      # captured so far. The body stays the server's to close.
      def abandon
        body ? body.abandon : finish("", 0, false, nil)
      end

      # Called by the body around its iteration, on the fiber that iterates it. Lends nothing
      # once the collectors are released.
      def enter
        token = CurrentContext.token
        CurrentContext.token = @profile.token
        lent = @mutex.synchronize do
          next [] if @released

          @collectors.filter_map do |collector|
            [collector, collector.lend_thread_slots] if collector.respond_to?(:lend_thread_slots)
          end
        end
        [token, lent]
      end

      def leave(state)
        token, lent = state
        lent.reverse_each { |collector, previous| collector.return_thread_slots(previous) }
        CurrentContext.token = token
      end
    end
  end
end
