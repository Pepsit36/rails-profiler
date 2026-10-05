# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class ViewCollector < BaseCollector
      def initialize(profile)
        super
        @views = []
        @partials = []
        @subscriptions = []
      end

      def icon
        "👁️"
      end

      def priority
        40
      end

      def tab_config
        {
          key: "view",
          label: "Views",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)

        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("render_template.action_view") do |name, started, finished, unique_id, payload|
          duration = ((finished - started) * 1000).round(2)
          @views << {
            identifier: payload[:identifier],
            layout: payload[:layout],
            duration: duration
          }
        end

        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("render_partial.action_view") do |name, started, finished, unique_id, payload|
          duration = ((finished - started) * 1000).round(2)
          @partials << {
            identifier: payload[:identifier],
            duration: duration
          }
        end
      end

      def collect
        unsubscribe

        data = {
          views: @views,
          partials: @partials,
          total_views: @views.size,
          total_partials: @partials.size,
          total_duration: (@views + @partials).sum { |v| v[:duration] }.round(2)
        }

        store_data(data)
      end

      # Collect reads only what the collector gathered itself.
      def collect_from_any_thread?
        true
      end

      def unsubscribe
        unsubscribe_notifications(@subscriptions)
      end

      def toolbar_summary
        total_duration = (@views + @partials).sum { |v| v[:duration] }.round(2)

        {
          text: "#{@views.size} views, #{@partials.size} partials (#{total_duration}ms)",
          color: "purple"
        }
      end
    end
  end
end
