# frozen_string_literal: true

module Profiler
  module Live
    # How many live event streams this process holds open. Each one keeps a server thread until it
    # ends, so they are counted and capped (config.live_events_max_streams).
    module Streams
      MUTEX = Mutex.new
      @open = 0

      class << self
        # True when a slot was taken: the caller must release it exactly once.
        def acquire(limit)
          MUTEX.synchronize do
            return false if @open >= limit

            @open += 1
            true
          end
        end

        def release
          MUTEX.synchronize { @open -= 1 if @open.positive? }
        end

        def open_count
          MUTEX.synchronize { @open }
        end

        def reset!
          MUTEX.synchronize { @open = 0 }
        end
      end
    end
  end
end
