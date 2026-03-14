# frozen_string_literal: true

require_relative "base_collector"
require_relative "../models/timeline_event"

module Profiler
  module Collectors
    class PerformanceCollector < BaseCollector
      def initialize(profile)
        super
        @events = []
        @subscriptions = []
      end

      def icon
        "⚡"
      end

      def priority
        30
      end

      def tab_config
        {
          key: "performance",
          label: "Performance",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)

        # Subscribe to controller processing
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("process_action.action_controller") do |name, started, finished, unique_id, payload|
          @events << Models::TimelineEvent.new(
            name: "Controller: #{payload[:controller]}##{payload[:action]}",
            started_at: started,
            finished_at: finished,
            payload: {
              controller: payload[:controller],
              action: payload[:action],
              format: payload[:format],
              method: payload[:method],
              path: payload[:path],
              status: payload[:status]
            }
          )
        end

        # Subscribe to view rendering
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("render_template.action_view") do |name, started, finished, unique_id, payload|
          @events << Models::TimelineEvent.new(
            name: "Render: #{payload[:identifier]}",
            started_at: started,
            finished_at: finished,
            payload: {
              identifier: payload[:identifier],
              layout: payload[:layout]
            }
          )
        end

        # Subscribe to partial rendering
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("render_partial.action_view") do |name, started, finished, unique_id, payload|
          @events << Models::TimelineEvent.new(
            name: "Partial: #{payload[:identifier]}",
            started_at: started,
            finished_at: finished,
            payload: {
              identifier: payload[:identifier]
            }
          )
        end
      end

      def collect
        # Unsubscribe from all notifications
        @subscriptions.each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }

        data = {
          total_events: @events.size,
          total_duration: @events.sum(&:duration).round(2),
          events: @events.map(&:to_h)
        }

        store_data(data)
      end

      def toolbar_summary
        duration = @events.sum(&:duration).round(2)

        {
          text: "#{@events.size} events (#{duration}ms)",
          color: "blue"
        }
      end
    end
  end
end
