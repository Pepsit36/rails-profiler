# frozen_string_literal: true

require "json"
require "time"
require "net/http"
require "uri"
require "digest"
require_relative "alerts/webhook"

module Profiler
  # Threshold alerts. When config.alerts_enabled is true, every profile saved is compared with the
  # thresholds the profiler already has (slow_query_threshold, max_queries_warning,
  # allocated_objects_warning_threshold) and checked for an N+1. Each detection is handed to
  # config.on_detection and, when config.alert_webhook_url is set, POSTed there as JSON.
  #
  # An alert carries no raw data: no body, no parameters, no SQL text with its literals, only the
  # normalized statement (the literals replaced with ?) and a fingerprint of it.
  #
  # Nothing here may reach the request: the hook and the webhook run in a rescue, and the webhook
  # on a thread of its own that holds nothing of the request.
  module Alerts
    TYPES = %w[slow_query too_many_queries excessive_allocations n_plus_one].freeze
    SQL_LIMIT = 200
    N_PLUS_ONE_LIMIT = 10

    module_function

    def check(profile)
      config = Profiler.configuration
      return unless config.alerts_enabled

      detections(profile, config).each { |alert| deliver(alert, config) }
    rescue StandardError => e
      Profiler.log_error("Alerts: could not check profile #{profile&.token}", e)
    end

    def detections(profile, config)
      base = base_payload(profile)
      alerts = []
      queries = queries_of(profile)
      alerts.concat(slow_query_alerts(base, queries, config))
      alerts.concat(too_many_queries_alerts(base, queries, config))
      alerts.concat(allocation_alerts(base, profile, config))
      alerts.concat(n_plus_one_alerts(base, queries))
      alerts
    end

    def base_payload(profile)
      request = profile.collector_data("request")
      {
        profile_token: profile.token,
        method: profile.method,
        path: profile.path,
        controller_action: request.is_a?(Hash) ? request["controller_action"] : nil,
        status: profile.status,
        detected_at: Time.now.utc.iso8601
      }
    end

    def queries_of(profile)
      data = profile.collector_data("database")
      list = data.is_a?(Hash) ? data["queries"] : nil
      list.is_a?(Array) ? list.select { |q| q["sql"].is_a?(String) } : []
    end

    def slow_query_alerts(base, queries, config)
      threshold = config.slow_query_threshold
      return [] unless threshold

      slow = queries.select { |q| q["duration"].to_f > threshold }
      return [] if slow.empty?

      slowest = slow.max_by { |q| q["duration"].to_f }
      [base.merge(type: "slow_query", threshold: threshold, unit: "ms", value: slowest["duration"].to_f,
                  count: slow.size, query: describe(slowest["sql"]))]
    end

    def too_many_queries_alerts(base, queries, config)
      threshold = config.max_queries_warning
      return [] unless threshold && queries.size > threshold

      [base.merge(type: "too_many_queries", threshold: threshold, unit: "queries", value: queries.size)]
    end

    def allocation_alerts(base, profile, config)
      threshold = config.allocated_objects_warning_threshold
      value = profile.allocated_objects
      return [] unless threshold && value && value > threshold

      [base.merge(type: "excessive_allocations", threshold: threshold, unit: "objects", value: value)]
    end

    def n_plus_one_alerts(base, queries)
      require_relative "mcp/resources/n1_patterns"
      groups = queries.group_by { |q| MCP::Resources::N1Patterns.normalize_sql(q["sql"]) }
      repeated = groups.select { |_, list| list.size > 1 }
      return [] if repeated.empty?

      [base.merge(type: "n_plus_one", threshold: 1, unit: "repeats", value: repeated.values.map(&:size).max,
                  patterns: patterns_of(repeated))]
    end

    def patterns_of(repeated)
      repeated.sort_by { |_, list| -list.size }.first(N_PLUS_ONE_LIMIT).map do |normalized, list|
        describe_normalized(normalized).merge(count: list.size)
      end
    end

    def describe(sql)
      describe_normalized(MCP::Resources::N1Patterns.normalize_sql(sql))
    end

    def describe_normalized(normalized)
      { sql: normalized[0, SQL_LIMIT], fingerprint: Digest::SHA256.hexdigest(normalized)[0, 12] }
    end

    def deliver(alert, config)
      call_hook(alert, config)
      post_webhook(alert, config)
    end

    def call_hook(alert, config)
      hook = config.on_detection
      hook&.call(alert)
    rescue StandardError => e
      Profiler.log_error("Alerts: config.on_detection raised for #{alert[:type]}", e)
    end

    def post_webhook(alert, config)
      Webhook.post(alert, config.alert_webhook_url, config.alert_webhook_timeout)
    end
  end
end
