# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class AjaxCollector < BaseCollector
      def initialize(profile, storage: Profiler.storage)
        super(profile)
        @storage = storage
      end

      def icon
        "🌐"
      end

      def priority
        25
      end

      def tab_config
        {
          key: "ajax",
          label: "AJAX",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        # Passive collector - no subscriptions needed
      end

      def collect
        ajax_profiles = @storage.find_by_parent(@profile.token)

        return store_data({}) if ajax_profiles.empty?

        # Generate summary statistics
        data = {
          "total_requests" => ajax_profiles.size,
          "total_duration" => ajax_profiles.sum(&:duration).round(2),
          "by_method" => group_by_method(ajax_profiles),
          "by_status" => group_by_status(ajax_profiles),
          "requests" => ajax_profiles.map { |p| request_summary(p) }
        }

        store_data(data)
      end

      def toolbar_summary
        return "" unless @data && @data["total_requests"]&.positive?

        total = @data["total_requests"]
        duration = @data["total_duration"]

        # Color coding based on number of requests
        color = if total > 20
                  "orange"
                elsif total > 50
                  "red"
                else
                  "green"
                end

        {
          text: "#{total} AJAX (#{duration}ms)",
          color: color
        }
      end

      private

      def group_by_method(profiles)
        profiles.group_by(&:method).transform_values(&:count)
      end

      def group_by_status(profiles)
        profiles.group_by { |p| status_category(p.status) }.transform_values(&:count)
      end

      def status_category(status)
        return "unknown" unless status

        case status
        when 200..299
          "2xx"
        when 300..399
          "3xx"
        when 400..499
          "4xx"
        when 500..599
          "5xx"
        else
          "other"
        end
      end

      def request_summary(profile)
        {
          "token" => profile.token,
          "path" => profile.path,
          "method" => profile.method,
          "status" => profile.status,
          "duration" => profile.duration,
          "started_at" => profile.started_at&.iso8601
        }
      end
    end
  end
end
