# frozen_string_literal: true

require_relative "base_collector"
require_relative "../instrumentation/net_http_instrumentation"

module Profiler
  module Collectors
    class HttpCollector < BaseCollector
      def initialize(profile)
        super
        @requests = []
      end

      def icon
        "🔗"
      end

      def priority
        35
      end

      def tab_config
        {
          key: "http",
          label: "Outbound HTTP",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        return unless Profiler.configuration.track_http

        Profiler::Instrumentation::NetHttpInstrumentation.install!
        Thread.current[:profiler_http_collector] = self
      end

      def collect
        Thread.current[:profiler_http_collector] = nil

        threshold = Profiler.configuration.slow_http_threshold

        store_data(
          total_requests: @requests.size,
          total_duration: @requests.sum { |r| r[:duration] }.round(2),
          slow_requests: @requests.count { |r| r[:duration] >= threshold },
          error_requests: @requests.count { |r| r[:status] >= 400 || r[:status] == 0 },
          by_host: group_by_host,
          by_status: group_by_status,
          requests: @requests.map { |r| r.transform_keys(&:to_s) }
        )
      end

      def record_request(payload)
        @requests << payload
      end

      def toolbar_summary
        total = @requests.size
        return { text: "0 HTTP", color: "green" } if total == 0

        threshold = Profiler.configuration.slow_http_threshold
        errors = @requests.count { |r| r[:status] >= 400 || r[:status] == 0 }
        slow = @requests.count { |r| r[:duration] >= threshold }
        duration = @requests.sum { |r| r[:duration] }.round(2)

        color = if errors > 0 || slow > 0
                  "red"
                elsif total > 10
                  "orange"
                else
                  "green"
                end

        { text: "#{total} HTTP (#{duration}ms)", color: color }
      end

      private

      def group_by_host
        @requests.each_with_object(Hash.new(0)) do |req, h|
          host = begin
            URI.parse(req[:url]).host || "unknown"
          rescue URI::InvalidURIError
            "unknown"
          end
          h[host] += 1
        end
      end

      def group_by_status
        @requests.each_with_object(Hash.new(0)) do |req, h|
          status = req[:status]
          key = if status == 0
                  "error"
                elsif status < 300
                  "2xx"
                elsif status < 400
                  "3xx"
                elsif status < 500
                  "4xx"
                else
                  "5xx"
                end
          h[key] += 1
        end
      end
    end
  end
end
