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
          Profiler::TestProfiler.profile(
            test_name: "#{self.class.name}##{name}",
            test_file:  self.class.instance_method(name).source_location&.first || "",
            test_line:  self.class.instance_method(name).source_location&.last || 0,
            framework:  :minitest
          ) { super }
        rescue NameError
          super
        end
      end
    end
  end
end
