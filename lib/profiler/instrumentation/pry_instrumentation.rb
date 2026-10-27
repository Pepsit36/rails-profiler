# frozen_string_literal: true

module Profiler
  module Instrumentation
    # Prepended to Pry. Pry commands (ls, cd...) do not go through #evaluate_ruby and are not profiled.
    module PryInstrumentation
      def evaluate_ruby(code)
        Profiler.env_override_store.apply!
        stripped = code.to_s.strip
        skip = !Profiler.enabled? ||
               !Profiler.configuration.track_console ||
               stripped.empty?
        return super if skip

        Profiler::ConsoleProfiler.profile(expression: stripped) { super }
      end
    end
  end
end
