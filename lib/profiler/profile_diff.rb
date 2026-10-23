# frozen_string_literal: true

require_relative "mcp/resources/n1_patterns"

module Profiler
  class ProfileDiff
    # A query is "slower" when its total time per fingerprint grew by more than this share.
    SLOWER_THRESHOLD_PCT = 20
    MAX_QUERIES_PER_BLOCK = 25

    attr_reader :profile_a, :profile_b

    def initialize(profile_a, profile_b, node_a: nil, node_b: nil)
      @profile_a = profile_a
      @profile_b = profile_b
      @node_a = node_a
      @node_b = node_b
    end

    def same_endpoint?
      profile_a.path == profile_b.path && profile_a.method == profile_b.method
    end

    def compute
      {
        profile_a: profile_summary(profile_a),
        profile_b: profile_summary(profile_b),
        same_endpoint: same_endpoint?,
        metrics: compute_metrics,
        sql: compare_sql,
        collectors: {
          database: compare_database,
          cache: compare_cache,
          views: compare_views,
          http: compare_http
        }
      }
    end

    private

    def compute_metrics
      db_a = profile_a.collector_data("database") || {}
      db_b = profile_b.collector_data("database") || {}
      cache_a = profile_a.collector_data("cache") || {}
      cache_b = profile_b.collector_data("cache") || {}
      view_a = profile_a.collector_data("view") || {}
      view_b = profile_b.collector_data("view") || {}
      http_a = profile_a.collector_data("http") || {}
      http_b = profile_b.collector_data("http") || {}

      {
        duration: metric_diff(
          profile_a.duration, profile_b.duration, :lower,
          threshold_pct: Profiler.configuration.regression_duration_threshold
        ),
        memory: metric_diff(
          profile_a.memory, profile_b.memory, :lower,
          threshold_pct: Profiler.configuration.regression_memory_threshold
        ),
        allocated_objects: metric_diff(
          profile_a.allocated_objects, profile_b.allocated_objects, :lower,
          threshold_pct: Profiler.configuration.regression_memory_threshold
        ),
        db_queries: metric_diff(
          db_a["total_queries"], db_b["total_queries"], :lower,
          threshold_pct: Profiler.configuration.regression_query_threshold
        ),
        db_duration: metric_diff(
          db_a["total_duration"], db_b["total_duration"], :lower,
          threshold_pct: Profiler.configuration.regression_duration_threshold
        ),
        cache_hit_rate: metric_diff(
          cache_a["hit_rate"], cache_b["hit_rate"], :higher,
          threshold_pct: Profiler.configuration.regression_cache_threshold
        ),
        view_duration: metric_diff(
          view_a["total_duration"], view_b["total_duration"], :lower,
          threshold_pct: Profiler.configuration.regression_duration_threshold
        ),
        http_requests: metric_diff(
          http_a["total_requests"], http_b["total_requests"], :lower,
          threshold_pct: 0
        ),
        http_duration: metric_diff(
          http_a["total_duration"], http_b["total_duration"], :lower,
          threshold_pct: Profiler.configuration.regression_duration_threshold
        )
      }
    end

    def metric_diff(val_a, val_b, direction, threshold_pct: 10)
      return nil if val_a.nil? && val_b.nil?

      a = val_a&.to_f
      b = val_b&.to_f
      delta = (b || 0) - (a || 0)
      delta_pct = (a && a != 0) ? (delta / a * 100).round(1) : nil

      status = compute_status(delta, delta_pct, direction, threshold_pct, val_a: val_a, val_b: val_b)

      { value_a: val_a, value_b: val_b, delta: delta.round(4), delta_pct: delta_pct, status: status }
    end

    def compute_status(delta, delta_pct, direction, threshold_pct, val_a: nil, val_b: nil)
      if delta == 0
        :neutral
      elsif val_a.nil? || val_b.nil?
        # Collector absent in one of the two profiles: no measurement to compare, stay neutral
        :neutral
      elsif delta_pct.nil?
        # Collector present but baseline is zero: apply direction logic directly without threshold
        if (direction == :lower && delta < 0) || (direction == :higher && delta > 0)
          :improved
        else
          :regression
        end
      else
        # Baseline is non-zero: apply threshold
        change_pct = delta_pct.abs
        if change_pct <= threshold_pct
          :neutral
        elsif (direction == :lower && delta < 0) || (direction == :higher && delta > 0)
          :improved
        else
          :regression
        end
      end
    end

    def profile_summary(profile)
      {
        token: profile.token,
        node: node_for(profile),
        path: profile.path,
        method: profile.method,
        status: profile.status,
        duration: profile.duration,
        memory: profile.memory,
        allocated_objects: profile.allocated_objects,
        started_at: profile.started_at,
        profile_type: profile.profile_type
      }
    end

    def node_for(profile)
      profile.equal?(profile_a) ? @node_a : @node_b
    end

    # The queries of both profiles grouped by normalized statement: those only B runs (new),
    # those only A ran (gone), and those whose total time grew past SLOWER_THRESHOLD_PCT.
    def compare_sql
      groups_a = sql_groups(profile_a)
      groups_b = sql_groups(profile_b)

      {
        new: (groups_b.keys - groups_a.keys).map { |k| sql_entry(k, nil, groups_b[k]) }
                                            .sort_by { |e| -e[:total_duration_b] }.first(MAX_QUERIES_PER_BLOCK),
        gone: (groups_a.keys - groups_b.keys).map { |k| sql_entry(k, groups_a[k], nil) }
                                             .sort_by { |e| -e[:total_duration_a] }.first(MAX_QUERIES_PER_BLOCK),
        slower: slower_sql(groups_a, groups_b)
      }
    end

    def slower_sql(groups_a, groups_b)
      (groups_a.keys & groups_b.keys).filter_map do |key|
        entry = sql_entry(key, groups_a[key], groups_b[key])
        next unless entry[:total_duration_a].positive?

        pct = ((entry[:total_duration_b] - entry[:total_duration_a]) / entry[:total_duration_a] * 100).round(1)
        entry.merge(delta_pct: pct) if pct > SLOWER_THRESHOLD_PCT
      end.sort_by { |e| -(e[:total_duration_b] - e[:total_duration_a]) }.first(MAX_QUERIES_PER_BLOCK)
    end

    def sql_groups(profile)
      queries = (profile.collector_data("database") || {})["queries"] || []
      queries.group_by { |q| MCP::Resources::N1Patterns.normalize_sql(q["sql"].to_s) }
    end

    def sql_entry(fingerprint, queries_a, queries_b)
      {
        fingerprint: fingerprint,
        count_a: queries_a&.size || 0,
        count_b: queries_b&.size || 0,
        total_duration_a: sql_total(queries_a),
        total_duration_b: sql_total(queries_b)
      }
    end

    def sql_total(queries)
      Array(queries).sum { |q| q["duration"].to_f }.round(2)
    end

    def compare_database
      db_a = profile_a.collector_data("database") || {}
      db_b = profile_b.collector_data("database") || {}

      queries_a = db_a["queries"] || []
      queries_b = db_b["queries"] || []

      {
        total_queries_a: db_a["total_queries"],
        total_queries_b: db_b["total_queries"],
        total_duration_a: db_a["total_duration"],
        total_duration_b: db_b["total_duration"],
        slow_queries_a: db_a["slow_queries"],
        slow_queries_b: db_b["slow_queries"],
        cached_queries_a: db_a["cached_queries"],
        cached_queries_b: db_b["cached_queries"],
        queries_a: queries_a.first(10),
        queries_b: queries_b.first(10)
      }
    end

    def compare_cache
      cache_a = profile_a.collector_data("cache") || {}
      cache_b = profile_b.collector_data("cache") || {}

      {
        total_reads_a: cache_a["total_reads"],
        total_reads_b: cache_b["total_reads"],
        total_writes_a: cache_a["total_writes"],
        total_writes_b: cache_b["total_writes"],
        hit_rate_a: cache_a["hit_rate"],
        hit_rate_b: cache_b["hit_rate"]
      }
    end

    def compare_views
      view_a = profile_a.collector_data("view") || {}
      view_b = profile_b.collector_data("view") || {}

      {
        total_views_a: view_a["total_views"],
        total_views_b: view_b["total_views"],
        views_a: rendered_templates(view_a),
        views_b: rendered_templates(view_b),
        total_partials_a: view_a["total_partials"],
        total_partials_b: view_b["total_partials"],
        total_duration_a: view_a["total_duration"],
        total_duration_b: view_b["total_duration"]
      }
    end

    def rendered_templates(view_data)
      Array(view_data["views"]).map { |v| v["identifier"].to_s }.tally
    end

    def compare_http
      http_a = profile_a.collector_data("http") || {}
      http_b = profile_b.collector_data("http") || {}

      {
        total_requests_a: http_a["total_requests"],
        total_requests_b: http_b["total_requests"],
        total_duration_a: http_a["total_duration"],
        total_duration_b: http_b["total_duration"],
        slow_requests_a: http_a["slow_requests"],
        slow_requests_b: http_b["slow_requests"],
        error_requests_a: http_a["error_requests"],
        error_requests_b: http_b["error_requests"]
      }
    end
  end
end
