# frozen_string_literal: true

require_relative "../collectors/lifecycle"

module Profiler
  module Middleware
    # The profile of a streamed response between the moment the application returns and the
    # moment the server closes the body. The collectors that read nothing from the request's
    # thread (Collectors::BaseCollector#collect_from_any_thread?) stay subscribed meanwhile, so
    # that the queries, views and logs of the stream are recorded.
    #
    # Rack requires the server to close the body, but nothing here relies on it alone: a
    # stream still open when the thread that started it starts another profiled request was
    # left behind, and is finished then; one subscribed for longer than
    # MAX_SUBSCRIBED_SECONDS has its collectors released by the next profiled request, from
    # any thread, and is saved when its body is closed.
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
        def sweep(thread = Thread.current)
          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          left, old = @lock.synchronize do
            [@pending.values.select { |s| s.thread == thread },
             @pending.values.select { |s| s.thread != thread && now - s.started_at > MAX_SUBSCRIBED_SECONDS }]
          end
          left.each(&:abandon)
          old.each do |streamed|
            unregister(streamed)
            streamed.release_collectors
          end
        end

        # Releases every stream still subscribed (specs, and a process shutting down).
        def release_all_pending
          @lock.synchronize { @pending.values.tap { @pending.clear } }.each(&:release_collectors)
        end
      end

      attr_reader :profile, :thread, :started_at
      attr_accessor :body

      # on_finish runs once, with what the body captured, when it is closed or abandoned.
      def initialize(profile, collectors, &on_finish)
        @profile = profile
        @collectors = collectors
        @on_finish = on_finish
        @thread = Thread.current
        @started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @mutex = Mutex.new
        @released = false
        @finished = false
      end

      # Collects the collectors kept for the stream and releases them, once, from any thread.
      def release_collectors
        @mutex.synchronize do
          return if @released

          @released = true
          @collectors.each do |collector|
            collector.collect if collector.respond_to?(:collect)
            @profile.refresh_collector_metadata(collector)
          rescue => e
            warn "Collector #{collector.class} failed: #{e.message}"
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

      # The server moved on without closing the body: finished with what it captured so far.
      def abandon
        body ? body.abandon : finish("", 0, false, nil)
      end
    end
  end
end
