# frozen_string_literal: true

require_relative "base_collector"
require_relative "../process_snapshot"

module Profiler
  module Collectors
    class RoutesCollector < BaseCollector
      def icon
        "🗺️"
      end

      def priority
        12
      end

      def tab_config
        {
          key: "routes",
          label: "Routes",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      # The route the request matched, and the size of the table: the table itself is the same
      # for every request, and is added back when the profile is displayed (ProcessSnapshot).
      def collect
        matched = ProcessSnapshot.matched_route(@profile.path, @profile.method)

        store_data({
          total: ProcessSnapshot.route_table.size,
          matched: matched && matched.merge(matched: true)
        })
      end

      def toolbar_summary
        data = panel_content
        matched = data[:matched]
        { text: matched ? matched[:pattern] : "\u2014", color: "blue" }
      end
    end
  end
end
