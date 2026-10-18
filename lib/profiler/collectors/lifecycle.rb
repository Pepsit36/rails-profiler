# frozen_string_literal: true

require_relative "circuit_breaker"

module Profiler
  module Collectors
    # Subscribes and releases the collectors of one profile, for every entry point that runs
    # them (the request middleware, jobs, console commands, tests).
    module Lifecycle
      module_function

      # Subscribes each collector in turn. A collector whose subscribe raises is released and
      # taken out of +collectors+ (the array is changed in place, so that the caller only collects
      # the ones that subscribed); the others keep profiling. Returns false, with every collector
      # released, only when none could subscribe: the caller then runs the work unprofiled.
      def subscribe_all(collectors, label)
        return true if collectors.empty?

        collectors.reject! { |collector| !subscribe_one(collector, label) }
        !collectors.empty?
      end

      # Runs the block that collects from one collector. A failure is logged and counted against
      # the collector's class (CircuitBreaker), a success clears that count; the others carry on.
      def guard(collector, label)
        yield
        CircuitBreaker.record_success(collector.class)
        true
      rescue => e
        Profiler.log_error("#{label}: collector #{collector.class} failed", e)
        CircuitBreaker.record_failure(collector.class)
        false
      end

      # Releases every collector, whatever happened before, one failure not stopping the others.
      def release_all(collectors)
        collectors&.each do |collector|
          collector.unsubscribe if collector.respond_to?(:unsubscribe)
        rescue => e
          Profiler.log_error("collector #{collector.class} release failed", e)
        end
      end

      def subscribe_one(collector, label)
        collector.subscribe if collector.respond_to?(:subscribe)
        true
      rescue => e
        Profiler.log_error("#{label}: collector #{collector.class} subscribe failed", e)
        CircuitBreaker.record_failure(collector.class)
        release_all([collector])
        false
      end
      private_class_method :subscribe_one
    end
  end
end
