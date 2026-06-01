# frozen_string_literal: true

module Profiler
  module Instrumentation
    module IrbInstrumentation
      IRB_SKIP_COMMANDS = %w[exit quit exit! irb help].freeze

      def evaluate(line, line_no, *args)
        Profiler.env_override_store.apply!
        stripped = line.to_s.strip
        skip = !Profiler.enabled? ||
               !Profiler.configuration.track_console ||
               stripped.empty? ||
               IRB_SKIP_COMMANDS.include?(stripped)
        return super if skip

        Profiler::ConsoleProfiler.profile(expression: stripped) { super }
      end
    end
  end
end
