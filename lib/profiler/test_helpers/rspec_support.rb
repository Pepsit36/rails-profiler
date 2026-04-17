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
            test_line:  example.line_number,
            framework:  :rspec
          ) { example.run }
        end

        config.after(:suite) do
          Profiler::TestHelpers::Reporter.print
        end
      end
    end
  end
end
