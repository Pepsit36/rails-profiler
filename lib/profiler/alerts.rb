# frozen_string_literal: true

require "json"
require "time"
require "net/http"
require "uri"
require "digest"
require_relative "alerts/webhook"
require_relative "alerts/sql_redaction"
# Alerts.normalize_sql wraps N1Patterns.normalize_sql. That file is otherwise only loaded by the MCP
# server, which an application without MCP never starts, so it is required here, not on first use.
require_relative "mcp/resources/n1_patterns"
require_relative "instrumentation/request_context"
require_relative "collectors/scoped_notifications"

module Profiler
  # Threshold alerts. When config.alerts_enabled is true, every profile saved is compared with the
  # thresholds the profiler already has (slow_query_threshold, max_queries_warning,
  # allocated_objects_warning_threshold) and checked for an N+1. Each detection is handed to
  # config.on_detection and, when config.alert_webhook_url is set, POSTed there as JSON.
  #
  # An alert carries no raw data: no body, no parameters, no header, only the SQL statement with
  # its literals replaced with ? (see SqlRedaction) and a fingerprint of it.
  #
  # Nothing here may slow or break the request: the whole check (the detections, which walk the
  # queries of the profile, then the hook and the webhook) runs on a thread of its own started
  # with RequestContext.detached, so it holds nothing of the request and `check` returns at once.
  # Each family of alert is detected in its own rescue, so an error on one never hides the others.
  module Alerts
    TYPES = %w[slow_query too_many_queries excessive_allocations n_plus_one].freeze
    SQL_LIMIT = 200
    N_PLUS_ONE_LIMIT = 10

    module_function

    # Starts the check on a thread detached from the request and returns it (nil when alerts are
    # off). The profile is saved and no longer written to by then.
    def check(profile)
      config = Profiler.configuration
      return unless config.alerts_enabled

      Instrumentation::RequestContext.detached { Thread.new { run(profile, config) } }
    rescue StandardError => e
      Profiler.log_error("Alerts: could not start the check of profile #{profile&.token}", e)
      nil
    end

    def run(profile, config)
      Collectors::ScopedNotifications.forget_inherited_scope
      detections(profile, config).each { |alert| deliver(alert, config) }
    rescue StandardError => e
      Profiler.log_error("Alerts: could not check profile #{profile&.token}", e)
    end

    # Every family in its own rescue: an error on one is logged and the others still go out.
    def detections(profile, config)
      base = base_payload(profile)
      queries = queries_of(profile)
      { slow_query: -> { slow_query_alerts(base, queries, config) },
        too_many_queries: -> { too_many_queries_alerts(base, queries, config) },
        excessive_allocations: -> { allocation_alerts(base, profile, config) },
        n_plus_one: -> { n_plus_one_alerts(base, queries) } }
        .flat_map { |family, detect| safely(family, profile, &detect) }
    rescue StandardError => e
      Profiler.log_error("Alerts: could not read profile #{profile&.token}", e)
      []
    end

    def safely(family, profile)
      yield
    rescue StandardError => e
      Profiler.log_error("Alerts: could not detect #{family} for profile #{profile&.token}", e)
      []
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
                  count: slow.size, query: describe_normalized(normalize_sql(slowest["sql"])))]
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
      groups = queries.group_by { |q| normalize_sql(q["sql"]) }
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

    # The shared normalization (numbers, $1 and simple quoted strings) after SqlRedaction.redact.
    def normalize_sql(sql)
      MCP::Resources::N1Patterns.normalize_sql(SqlRedaction.redact(sql))
    end

    def describe_normalized(normalized)
      { sql: normalized[0, SQL_LIMIT], fingerprint: Digest::SHA256.hexdigest(normalized)[0, 12] }
    end

    def deliver(alert, config)
      call_hook(alert, config)
      Webhook.post(alert, config.alert_webhook_url, config.alert_webhook_timeout)
    end

    def call_hook(alert, config)
      hook = config.on_detection
      hook&.call(alert)
    rescue StandardError => e
      Profiler.log_error("Alerts: config.on_detection raised for #{alert[:type]}", e)
    end
  end
end
