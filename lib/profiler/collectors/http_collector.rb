# frozen_string_literal: true

require_relative "base_collector"
require_relative "../instrumentation/net_http_instrumentation"

module Profiler
  module Collectors
    class HttpCollector < BaseCollector
      def initialize(profile)
        super
        @requests = []
        @mutex = Mutex.new
        @collected = false
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
        claim_thread_slot(:profiler_http_collector, self)
      end

      # The Net::HTTP patch installed by subscribe stays: it is installed once per process and
      # records nothing when no collector holds the thread-local slot.
      def unsubscribe
        restore_thread_slots
      end

      def collect
        unsubscribe

        data = @mutex.synchronize do
          @collected = true
          build_data(@requests)
        end
        store_data(data)
      end

      # Called from NetHttpInstrumentation before the actual HTTP call.
      # Returns the mutable entry so the caller can update it on completion.
      def register_pending(payload)
        entry = payload.merge(in_flight: true, status: 0, duration: nil,
                              response_headers: {}, response_body: nil,
                              response_body_encoding: "text", response_size: 0)
        @mutex.synchronize { @requests << entry }
        save_if_collected
        entry
      end

      # Called from NetHttpInstrumentation after the HTTP response is received.
      def complete_request(entry, **data)
        @mutex.synchronize { entry.merge!(data.merge(in_flight: false)) }
        save_if_collected
      end

      # Called from NetHttpInstrumentation when the HTTP call raises.
      def fail_request(entry, error:, duration:)
        @mutex.synchronize { entry.merge!(in_flight: false, status: 0, duration: duration, error: error) }
        save_if_collected
      end

      def toolbar_summary
        requests = @mutex.synchronize { @requests.dup }
        total = requests.size
        return { text: "0 HTTP", color: "green" } if total == 0

        threshold = Profiler.configuration.slow_http_threshold
        in_flight = requests.count { |r| r[:in_flight] }
        errors = requests.count { |r| !r[:in_flight] && (r[:status] >= 400 || r[:status] == 0) }
        slow = requests.count { |r| !r[:in_flight] && r[:duration] && r[:duration] >= threshold }
        duration = requests.sum { |r| r[:duration].to_f }.round(2)

        color = if errors > 0 || slow > 0
                  "red"
                elsif in_flight > 0 || total > 10
                  "orange"
                else
                  "green"
                end

        text = in_flight > 0 ? "#{total} HTTP (#{in_flight} pending, #{duration}ms)" : "#{total} HTTP (#{duration}ms)"
        { text: text, color: color }
      end

      private

      def build_data(requests)
        threshold = Profiler.configuration.slow_http_threshold
        {
          total_requests: requests.size,
          total_duration: requests.sum { |r| r[:duration].to_f }.round(2),
          slow_requests: requests.count { |r| !r[:in_flight] && r[:duration] && r[:duration] >= threshold },
          error_requests: requests.count { |r| !r[:in_flight] && (r[:status] >= 400 || r[:status] == 0) },
          by_host: group_by_host(requests),
          by_status: group_by_status(requests),
          requests: requests.map { |r| r.transform_keys(&:to_s) }
        }
      end

      # Rebuilds and persists HTTP data after collect has already run.
      # Called when fire-and-forget threads register or complete requests post-collect.
      def save_if_collected
        data = @mutex.synchronize do
          return unless @collected

          build_data(@requests)
        end
        store_data(data)
        Profiler.save_profile(@profile, from: "HttpCollector")
      end

      def group_by_host(requests)
        requests.each_with_object(Hash.new(0)) do |req, h|
          host = begin
            URI.parse(req[:url]).host || "unknown"
          rescue URI::InvalidURIError
            "unknown"
          end
          h[host] += 1
        end
      end

      def group_by_status(requests)
        requests.each_with_object(Hash.new(0)) do |req, h|
          key = if req[:in_flight]
                  "pending"
                elsif req[:status] == 0
                  "error"
                elsif req[:status] < 300
                  "2xx"
                elsif req[:status] < 400
                  "3xx"
                elsif req[:status] < 500
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
