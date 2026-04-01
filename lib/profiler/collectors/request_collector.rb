# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class RequestCollector < BaseCollector
      def icon
        "🌐"
      end

      def priority
        10
      end

      def tab_config
        {
          key: "request",
          label: "Request",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def collect
        data = {
          path: @profile.path,
          method: @profile.method,
          status: @profile.status,
          duration: @profile.duration,
          memory: @profile.memory,
          params: @profile.params,
          headers: @profile.headers,
          response_headers: @profile.response_headers,
          request_body: @profile.request_body,
          request_body_encoding: @profile.request_body_encoding,
          response_body: @profile.response_body,
          response_body_encoding: @profile.response_body_encoding,
          started_at: @profile.started_at&.iso8601,
          finished_at: @profile.finished_at&.iso8601
        }

        data.merge!(collect_route_info)
        store_data(data)
      end

      def toolbar_summary
        status_color = case @profile.status
                      when 200..299 then "green"
                      when 300..399 then "blue"
                      when 400..499 then "orange"
                      when 500..599 then "red"
                      else "gray"
                      end

        {
          text: "#{@profile.method} #{@profile.status}",
          color: status_color,
          duration: @profile.duration,
          memory: format_memory(@profile.memory)
        }
      end

      private

      def collect_route_info
        return {} unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

        path   = @profile.path
        method = @profile.method

        recognized = Rails.application.routes.recognize_path(path, method: method)

        controller = recognized[:controller]
        action     = recognized[:action]

        controller_action = if controller && action
          "#{controller.split('/').map { |s| ActiveSupport::Inflector.camelize(s) }.join('::')}Controller##{action}"
        end

        route_params = recognized.except(:controller, :action, :format)

        route_name, matched_route = Rails.application.routes.named_routes.find do |_name, route|
          route.defaults[:controller] == controller &&
            route.defaults[:action]    == action &&
            route.path.match(path)
        end

        {
          route_name:        route_name ? "#{route_name}_path" : nil,
          route_pattern:     matched_route&.path&.spec&.to_s&.sub(/\(\.:format\)$/, ""),
          route_params:      route_params,
          controller_action: controller_action
        }
      rescue StandardError
        {}
      end

      def format_memory(bytes)
        return "0 B" unless bytes

        if bytes < 1024
          "#{bytes} B"
        elsif bytes < 1024 * 1024
          "#{(bytes / 1024.0).round(2)} KB"
        else
          "#{(bytes / 1024.0 / 1024.0).round(2)} MB"
        end
      end
    end
  end
end
