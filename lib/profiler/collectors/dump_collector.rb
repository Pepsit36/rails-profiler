# frozen_string_literal: true

require_relative "base_collector"
require "pp"

module Profiler
  module Collectors
    class DumpCollector < BaseCollector
      def icon
        "🔍"
      end

      def priority
        15
      end

      def name
        "dump"
      end

      def tab_config
        {
          key: "dump",
          label: "Dumps",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def collect
        dumps = Thread.current[:profiler_dumps] || []

        formatted_dumps = dumps.map do |dump|
          {
            value: dump[:value],
            formatted: format_value(dump[:value]),
            file: dump[:file],
            line: dump[:line],
            label: dump[:label],
            timestamp: dump[:timestamp]
          }
        end

        store_data({
          count: formatted_dumps.size,
          dumps: formatted_dumps
        })

        # Clear dumps for next request
        Thread.current[:profiler_dumps] = []
      end

      def toolbar_summary
        count = @data[:count] || 0
        color = count > 0 ? "blue" : "gray"

        {
          text: "#{count} dump#{count != 1 ? 's' : ''}",
          color: color
        }
      end

      private

      def format_value(value)
        case value
        when String
          value.inspect
        when Array, Hash
          PP.pp(value, +"", 120).strip
        when NilClass
          "nil"
        when TrueClass, FalseClass
          value.to_s
        when Numeric
          value.to_s
        else
          # For objects, show class and instance variables
          formatted = "#<#{value.class}:0x#{value.object_id.to_s(16)}"
          ivars = value.instance_variables
          if ivars.any?
            formatted += " "
            formatted += ivars.map do |ivar|
              ivar_value = value.instance_variable_get(ivar)
              "#{ivar}=#{ivar_value.inspect}"
            end.join(", ")
          end
          formatted += ">"
          formatted
        end
      rescue => e
        "[Error formatting value: #{e.message}]"
      end
    end
  end
end
