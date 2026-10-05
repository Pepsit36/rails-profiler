# frozen_string_literal: true

require_relative "base_collector"
require_relative "../process_snapshot"

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

      # ENV is the process's, not the request's: the profile keeps none of it, and the Env tab
      # shows the variables of the process that displays the profile (ProcessSnapshot).
      def collect
        store_data({ scope: "process" })
      end

      def toolbar_summary
        { text: "#{ENV.size} vars", color: "gray" }
      end
    end
  end
end
