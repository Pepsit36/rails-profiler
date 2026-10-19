# frozen_string_literal: true

require_relative "sdk"
require_relative "trace_exporter"
require_relative "../mcp/resources/n1_patterns"

module Profiler
  module Otel
    # Records a finished request profile in OpenTelemetry metrics: duration histograms (request,
    # SQL query, view or partial, cache operation, outbound HTTP call; milliseconds, the unit the
    # profiler measures in), a counter of the objects the request allocated, and a counter of the
    # requests that ran an N+1. The events are the ones TraceExporter turns into spans, here
    # aggregated.
    #
    # Attributes are kept to a bounded set of values, on purpose (unlike spans, a metric is one
    # time series per attribute combination): controller#action (or "unknown"), the HTTP method
    # (a standard verb, else "_OTHER"), the status code (request duration only), the SQL verb
    # (SELECT, INSERT, UPDATE, DELETE, else "OTHER") and the cache operation. Never a profile
    # token, a path or URL, SQL text, a cache key or a host.
    #
    # The metrics SDK is alpha: its API moves between releases (see docs/configuration.md).
    # Does nothing, and touches nothing of OpenTelemetry, unless config.otel_enabled is true.
    # Never raises: a failure is logged and the request goes on.
    module MetricsExporter
      SCOPE_NAME = "profiler"
      UNKNOWN = "unknown"
      HTTP_METHODS = %w[GET HEAD POST PUT PATCH DELETE OPTIONS CONNECT TRACE].freeze
      SQL_VERBS = %w[SELECT INSERT UPDATE DELETE].freeze

      module_function

      def export(profile)
        return false unless Profiler.configuration.otel_enabled

        provider = Sdk.meter_provider
        return false unless provider

        record(instruments(provider), profile)
        true
      rescue StandardError => e
        Profiler.log_error_once(:otel_metrics_export, "OpenTelemetry metrics export of a profile failed", e)
        false
      end

      # The instruments of a provider (the meter caches them by name, so asking again is cheap).
      def instruments(provider)
        meter = provider.meter(SCOPE_NAME, version: Profiler.version)
        {
          request: meter.create_histogram("profiler.request.duration", unit: "ms",
                                                                       description: "Duration of a profiled HTTP request"),
          sql: meter.create_histogram("profiler.db.query.duration", unit: "ms",
                                                                    description: "Duration of a SQL query"),
          view: meter.create_histogram("profiler.view.render.duration", unit: "ms",
                                                                        description: "Duration of a view or partial render"),
          cache: meter.create_histogram("profiler.cache.operation.duration", unit: "ms",
                                                                             description: "Duration of a cache operation"),
          http: meter.create_histogram("profiler.http.client.request.duration", unit: "ms",
                                                                                description: "Duration of an outbound Net::HTTP call"),
          allocations: meter.create_counter("profiler.request.allocations", unit: "{object}",
                                                                            description: "Objects allocated by profiled requests"),
          n_plus_one: meter.create_counter("profiler.request.n_plus_one", unit: "{request}",
                                                                          description: "Profiled requests that ran an N+1 query")
        }
      end

      def record(instruments, profile)
        data = profile.collectors_data || {}
        base = { "profiler.controller_action" => controller_action(data), "http.request.method" => method_name(profile.method) }

        request_attributes = base.dup
        request_attributes["http.response.status_code"] = profile.status.to_i if (100..599).cover?(profile.status.to_i)
        instruments[:request].record(profile.duration.to_f, attributes: request_attributes) if profile.duration

        queries = queries(data)
        queries.each do |query|
          instruments[:sql].record(query[:duration].to_f, attributes: base.merge("db.operation.name" => sql_verb(query[:sql])))
        end
        record_all(instruments[:view], base, views(data))
        record_cache(instruments[:cache], base, data)
        record_all(instruments[:http], base, TraceExporter.list(TraceExporter.fetch(data, "http"), :requests).reject { |r| r[:in_flight] })

        allocations = profile.allocated_objects
        instruments[:allocations].add(allocations, attributes: base) if allocations.is_a?(Integer) && allocations.positive?
        instruments[:n_plus_one].add(1, attributes: base) if n_plus_one?(queries)
      end

      def record_all(histogram, attributes, events)
        events.each { |event| histogram.record(event[:duration].to_f, attributes: attributes) if event[:duration] }
      end

      def record_cache(histogram, base, data)
        cache = TraceExporter.fetch(data, "cache")
        %i[reads writes deletes].each do |kind|
          operation = kind.to_s.chomp("s")
          TraceExporter.list(cache, kind).each do |event|
            next unless event[:duration]

            histogram.record(event[:duration].to_f, attributes: base.merge("cache.operation" => operation))
          end
        end
      end

      def views(data)
        view = TraceExporter.fetch(data, "view")
        TraceExporter.list(view, :views) + TraceExporter.list(view, :partials)
      end

      # The SQL queries of the request, transaction statements apart (the Database tab does too).
      def queries(data)
        TraceExporter.list(TraceExporter.fetch(data, "database"), :queries).reject { |q| q[:transaction] || q[:duration].nil? }
      end

      # An N+1 here: some query, once its constants are normalized (N1Patterns.normalize_sql, the
      # one the n1-patterns resource uses), ran more than once within this one request.
      def n_plus_one?(queries)
        queries.group_by { |q| MCP::Resources::N1Patterns.normalize_sql(q[:sql].to_s) }.any? { |_, group| group.size > 1 }
      end

      def controller_action(data)
        value = TraceExporter.fetch(data, "request")[:controller_action] || TraceExporter.fetch(data, "request")["controller_action"]
        value.to_s.empty? ? UNKNOWN : value.to_s
      end

      def method_name(method)
        name = method.to_s.upcase
        HTTP_METHODS.include?(name) ? name : "_OTHER"
      end

      def sql_verb(sql)
        verb = sql.to_s[/\A\s*(\w+)/, 1].to_s.upcase
        SQL_VERBS.include?(verb) ? verb : "OTHER"
      end
    end
  end
end
