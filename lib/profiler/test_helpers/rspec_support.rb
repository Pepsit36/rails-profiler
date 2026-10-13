# frozen_string_literal: true

require_relative "../test_profiler"
require_relative "reporter"

module Profiler
  module TestHelpers
    # RSpec integration for the profiler.
    #
    # Usage in spec_helper.rb:
    #
    #   require 'profiler/test_helpers/rspec_support'
    #   RSpec.configure do |config|
    #     Profiler::TestHelpers::RSpecSupport.install(config)
    #   end
    module RSpecSupport
      def self.install(config)
        config.around(:each) do |example|
          Profiler::TestProfiler.profile(
            test_name: example.full_description,
            test_file:  example.file_path,
            test_line:  example.metadata[:line_number],
            framework:  :rspec
          ) do
            example.run
            Outcome.new(example)
          end
        end

        config.after(:suite) do
          Profiler::TestHelpers::Reporter.print
        end
      end

      # What the profiled block hands back to TestProfiler: the same interface as
      # Minitest::Result (passed?, skipped?, failure).
      #
      # Procsy#run returns a boolean, and execution_result.status is still nil at
      # this point: Example#finish only writes it once every around hook has
      # returned. The outcome is read from the state #finish relies on, in the
      # same order: an exception means failed, then a pending message (from
      # `pending` or `skip` in the example) means pending.
      class Outcome
        Reason = Struct.new(:message)

        def initialize(example)
          @exception = example.exception
          @pending_message = example.execution_result.pending_message
        end

        def passed?
          @exception.nil? && @pending_message.nil?
        end

        def skipped?
          @exception.nil? && !@pending_message.nil?
        end

        def failure
          return @exception if @exception

          Reason.new(@pending_message) if @pending_message
        end
      end
    end
  end
end
