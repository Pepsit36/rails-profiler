# frozen_string_literal: true

module Profiler
  module Collectors
    # One circuit per collector class, shared by the threads and requests of the process. A
    # class that fails config.collector_circuit_breaker_threshold times in a row (a subscribe or
    # a collect that raises) is no longer instantiated: its circuit is open. After RECOVERY_SECONDS
    # a single request tries it again (half open): a success closes the circuit, a failure
    # opens it again for another RECOVERY_SECONDS. With the option off, nothing is counted and
    # nothing is blocked.
    module CircuitBreaker
      RECOVERY_SECONDS = 60

      # state: :closed, :open or :half_open. +since+ is when the circuit opened, or when the
      # trial of a half open one was granted.
      Circuit = Struct.new(:failures, :state, :since)

      LOCK = Mutex.new
      CIRCUITS = {}
      private_constant :LOCK, :CIRCUITS

      module_function

      def enabled?
        Profiler.configuration.collector_circuit_breaker_enabled ? true : false
      end

      # Whether a collector of this class is to be created for the next profile. An open circuit
      # whose delay has passed answers true once, and becomes half open; a half open one answers
      # false while its trial is under way, unless that trial never reported for RECOVERY_SECONDS.
      def allow?(collector_class)
        return true unless enabled?

        LOCK.synchronize do
          circuit = CIRCUITS[collector_class]
          return true unless circuit

          case circuit.state
          when :closed then true
          else
            return false if now - circuit.since < RECOVERY_SECONDS

            circuit.state = :half_open
            circuit.since = now
            true
          end
        end
      end

      def record_failure(collector_class)
        return unless enabled?

        LOCK.synchronize do
          circuit = (CIRCUITS[collector_class] ||= Circuit.new(0, :closed, nil))
          circuit.failures += 1
          if circuit.state == :half_open || circuit.failures >= Profiler.configuration.collector_circuit_breaker_threshold
            circuit.state = :open
            circuit.since = now
          end
        end
      end

      def record_success(collector_class)
        return unless enabled?

        LOCK.synchronize do
          circuit = CIRCUITS[collector_class]
          return unless circuit

          # A late success of a request that started before the circuit opened does not close it.
          return if circuit.state == :open

          CIRCUITS.delete(collector_class)
        end
      end

      # { state:, failures: } for one class, without changing anything. An open circuit whose
      # delay has passed is reported half open: the next request will try it.
      def status(collector_class)
        return { state: :closed, failures: 0 } unless enabled?

        LOCK.synchronize do
          circuit = CIRCUITS[collector_class]
          return { state: :closed, failures: 0 } unless circuit

          state = circuit.state
          state = :half_open if state == :open && now - circuit.since >= RECOVERY_SECONDS
          { state: state, failures: circuit.failures }
        end
      end

      def reset!
        LOCK.synchronize { CIRCUITS.clear }
      end

      # Monotonic seconds; a spec replaces it to move time.
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
