# frozen_string_literal: true

module Profiler
  module Live
    # The live event streams this process holds open. Each one keeps a server thread until it
    # ends, so they are counted and capped (config.live_events_max_streams). A lease older than
    # MAX_AGE is dropped on the next acquire: a body that a middleware or the server threw away
    # without iterating or closing it (Rack::Head does) cannot keep a slot for good.
    module Streams
      MUTEX = Mutex.new
      MAX_AGE = 330
      @leases = {}

      class << self
        # A lease when a slot was taken (to give back with release), nil over the limit.
        def acquire(limit)
          MUTEX.synchronize do
            now = clock
            @leases.delete_if { |_lease, taken| now - taken > MAX_AGE }
            return nil if @leases.size >= limit

            lease = Object.new
            @leases[lease] = now
            lease
          end
        end

        def release(lease)
          MUTEX.synchronize { @leases.delete(lease) }
        end

        def open_count
          MUTEX.synchronize { @leases.size }
        end

        def reset!
          MUTEX.synchronize { @leases.clear }
        end

        private

        def clock
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
