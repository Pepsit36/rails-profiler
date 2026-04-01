# frozen_string_literal: true

require_relative "base_collector"

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

      def collect
        unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application
          return store_data({ routes: [], total: 0 })
        end

        matched_controller, matched_action = recognize_current_route
        routes = build_routes_list(matched_controller, matched_action)
        matched_route = routes.find { |r| r[:matched] }

        store_data({
          total: routes.size,
          matched: matched_route,
          routes: routes
        })
      end

      def toolbar_summary
        data = panel_content
        matched = data[:matched]
        { text: matched ? matched[:pattern] : "—", color: "blue" }
      end

      private

      def recognize_current_route
        recognized = Rails.application.routes.recognize_path(@profile.path, method: @profile.method)
        [recognized[:controller], recognized[:action]]
      rescue StandardError
        [nil, nil]
      end

      def build_routes_list(matched_controller, matched_action)
        Rails.application.routes.routes.filter_map do |route|
          next if route.respond_to?(:internal) && route.internal

          controller = route.defaults[:controller]
          action = route.defaults[:action]
          next if controller.nil?
          next if controller.start_with?("rails/", "profiler/")

          name = route.name
          pattern = route.path.spec.to_s.sub(/\(\.:format\)$/, "")
          v = route.verb
          verb = (v && !v.empty?) ? v : "ANY"

          controller_action = if controller && action
            "#{controller.split("/").map { |s| ActiveSupport::Inflector.camelize(s) }.join("::")}Controller##{action}"
          end

          {
            name: name,
            pattern: pattern,
            verb: verb,
            controller_action: controller_action,
            matched: controller == matched_controller && action == matched_action
          }
        end
      rescue StandardError
        []
      end
    end
  end
end
