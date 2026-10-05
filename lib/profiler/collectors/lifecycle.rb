# frozen_string_literal: true

module Profiler
  module Collectors
    # Subscribes and releases the collectors of one profile, for every entry point that runs
    # them (the request middleware, jobs, console commands, tests).
    module Lifecycle
      module_function

      # Subscribes each collector in turn. When one fails, releases them all, the ones that
      # never subscribed included, and returns false: the caller then runs the work unprofiled.
      def subscribe_all(collectors, label)
        collectors.each { |collector| collector.subscribe if collector.respond_to?(:subscribe) }
        true
      rescue => e
        Profiler.log_error("#{label}: collector subscribe failed", e)
        release_all(collectors)
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
    end
  end
end
