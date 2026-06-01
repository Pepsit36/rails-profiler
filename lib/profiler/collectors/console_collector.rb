# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class ConsoleCollector < BaseCollector
      def initialize(profile, expression:)
        super(profile)
        @expression = expression
        @return_value = nil
        @return_value_captured = false
      end

      def set_return_value(value)
        @return_value = value.inspect.slice(0, 10_000)
        @return_value_captured = true
      rescue
        @return_value = "(uninspectable)"
        @return_value_captured = true
      end

      def icon
        ">_"
      end

      def priority
        5
      end

      def tab_config
        {
          key: "console",
          label: "Console",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: true
        }
      end

      def collect
        data = { expression: @expression }
        data[:return_value] = @return_value if @return_value_captured
        store_data(data)
      end

      def has_data?
        @expression.to_s.length > 0
      end

      def toolbar_summary
        { text: @expression.to_s[0, 30], color: "blue" }
      end
    end
  end
end
