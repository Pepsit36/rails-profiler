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
          allocated_objects: @profile.allocated_objects,
          memory: @profile.memory, # deprecated, see Profile#memory
          params: @profile.params,
          headers: @profile.headers,
          response_headers: @profile.response_headers,
          request_body: @profile.request_body,
          request_body_encoding: @profile.request_body_encoding,
          response_body: @profile.response_body,
          response_body_encoding: @profile.response_body_encoding,
          request_body_size: @profile.request_body_size,
          request_body_truncated: @profile.request_body_truncated || false,
          request_body_size_is_minimum: @profile.request_body_size_is_minimum || false,
          response_body_size: @profile.response_body_size,
          response_body_truncated: @profile.response_body_truncated || false,
          response_body_size_is_minimum: @profile.response_body_size_is_minimum || false,
          # A streamed response whose collectors were released before its body was closed.
          collectors_released_after_seconds: @profile.collectors_released_after_seconds,
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
          allocated_objects: format_allocations(@profile.allocated_objects)
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
          route_params:      Profiler::Redaction.filter_hash(route_params),
          controller_action: controller_action
        }
      rescue StandardError => e
        # A path no route matches (a 404) has no route to show.
        unless defined?(ActionController::RoutingError) && e.is_a?(ActionController::RoutingError)
          Profiler.log_error_once(:request_route, "RequestCollector: could not read the matched route", e)
        end
        {}
      end

      def format_allocations(count)
        return "0 objects" unless count

        "#{count.to_s.reverse.scan(/\d{1,3}/).join(",").reverse} objects"
      end
    end
  end
end
