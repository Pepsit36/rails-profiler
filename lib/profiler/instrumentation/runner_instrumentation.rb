# frozen_string_literal: true

module Profiler
  module Instrumentation
    # Prepended to Rails.application.executor by the railtie's runner hook, which runs before
    # the code does. `rails runner` evaluates the code inside executor.wrap with this source:
    # the one place that sees the whole execution, its result and its exception. Skipped with
    # `runner -w`, which does not use the executor.
    module RunnerInstrumentation
      RUNNER_SOURCE = "application.runner.railties"

      def wrap(*args, source: nil, **options, &block)
        return super unless source == RUNNER_SOURCE && block

        expression = RunnerInstrumentation.expression_for(block)
        return super if Profiler.configuration.runner_skipped?(expression)

        Profiler::ConsoleProfiler.profile(expression: expression, source: "runner") do
          super(*args, source: source, **options, &block)
        end
      end

      # The runner's own block closes over the command line: code_or_file is the code, the
      # script path, or "-" for standard input.
      def self.expression_for(block)
        value = block.binding.local_variable_get(:code_or_file).to_s
        value == "-" ? "(stdin)" : value
      rescue NameError
        "(runner)"
      end
    end
  end
end
