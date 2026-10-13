# frozen_string_literal: true

require_relative "../test_profiler"
require_relative "reporter"

module Profiler
  module TestHelpers
    # Minitest integration for the profiler.
    #
    # Usage in test_helper.rb:
    #
    #   require 'profiler/test_helpers/minitest_support'
    #   Profiler::TestHelpers::MinitestSupport.install
    module MinitestSupport
      def self.install
        require "minitest"

        Minitest::Test.prepend(RunWrapper)

        Minitest.after_run do
          Profiler::TestHelpers::Reporter.print
        end
      end

      module RunWrapper
        def run
          file, line = profiler_test_location
          Profiler::TestProfiler.profile(
            test_name: "#{self.class.name}##{name}",
            test_file:  file,
            test_line:  line,
            framework:  :minitest
          ) { super }
        end

        private

        # Only the lookup is guarded: rescuing around super would run the test
        # again whenever anything raised a NameError after it, NoMethodError
        # included.
        def profiler_test_location
          location = self.class.instance_method(name).source_location
          [location&.first || "", location&.last || 0]
        rescue NameError
          ["", 0]
        end
      end
    end
  end
end
