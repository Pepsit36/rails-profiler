# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class EnvCollector < BaseCollector
      def icon
        "⚙️"
      end

      def priority
        90
      end

      def tab_config
        {
          key: "env",
          label: "Env",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def collect
        variables = Profiler::Redaction.env_snapshot
        store_data({ variables: variables, total: variables.size })
      end

      def toolbar_summary
        data = panel_content
        { text: "#{data[:total] || 0} vars", color: "gray" }
      end
    end
  end
end
