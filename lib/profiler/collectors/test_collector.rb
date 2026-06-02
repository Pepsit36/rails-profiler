# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class TestCollector < BaseCollector
      def initialize(profile, test_name:, test_file:, test_line:, framework:)
        super(profile)
        @test_name = test_name
        @test_file = test_file
        @test_line = test_line
        @framework = framework
        @status = "running"
        @exception_message = nil
      end

      def icon
        "🧪"
      end

      def priority
        5
      end

      def tab_config
        {
          key: "test",
          label: "Test",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: true
        }
      end

      def update_status(status, exception_message = nil)
        @status = status
        @exception_message = exception_message
      end

      def update_extra(assertions: nil, skip_reason: nil)
        @assertions = assertions
        @skip_reason = skip_reason
      end

      def collect
        store_data({
          test_name: @test_name,
          test_file: @test_file,
          test_line: @test_line,
          framework: @framework.to_s,
          status: @status,
          exception_message: @exception_message,
          assertions: @assertions,
          skip_reason: @skip_reason
        })
      end

      def has_data?
        true
      end

      def toolbar_summary
        color = case @status
                when "passed"  then "green"
                when "failed"  then "red"
                when "pending" then "orange"
                else "gray"
                end
        { text: @status, color: color }
      end
    end
  end
end
