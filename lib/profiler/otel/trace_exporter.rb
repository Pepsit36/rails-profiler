# frozen_string_literal: true

require "time"
require "uri"
require_relative "sdk"

module Profiler
  module Otel
    # Sends a finished request profile to OpenTelemetry as one trace: a root span for the request,
    # a child span for each SQL query, view or partial rendering, cache operation and outbound
    # HTTP call the collectors already recorded (nothing is instrumented twice). The root span
    # carries the profile's own trace_id and span_id, so that the trace in the collector and the
    # profile in the dashboard are the same thing; a traceparent received with the request makes
    # the root a child of the caller's span, as the profile already says.
    #
    # Does nothing, and touches nothing of OpenTelemetry, unless config.otel_enabled is true.
    # Never raises: an export that fails is logged and the request goes on.
    module TraceExporter
      SCOPE_NAME = "profiler"
      SAMPLED_FLAG = 1

      module_function

      def export(profile)
        return false unless Profiler.configuration.otel_enabled
        return false unless profile.trace_id && profile.span_id

        provider = Sdk.tracer_provider
        return false unless provider

        emit(provider.tracer(SCOPE_NAME, Profiler.version), profile)
        true
      rescue StandardError => e
        Profiler.log_error_once(:otel_export, "OpenTelemetry export of a profile failed", e)
        false
      end

      def emit(tracer, profile)
        started = profile.started_at || Time.now
        finished = profile.finished_at || started
        root = start_root(tracer, profile, started)
        parent = OpenTelemetry::Trace.context_with_span(root)

        children(profile).each do |child|
          start = child[:started_at] || started
          span = tracer.start_span(child[:name], with_parent: parent, kind: child[:kind],
                                                 attributes: child[:attributes], start_timestamp: start)
          mark_error(span, child[:error])
          span.finish(end_timestamp: start + child[:duration].to_f / 1000.0)
        end

        root_status(root, profile)
        root.finish(end_timestamp: finished)
      end

      def start_root(tracer, profile, started)
        attributes = {
          "http.request.method" => profile.method.to_s,
          "url.path" => profile.path.to_s,
          "profiler.token" => profile.token.to_s
        }
        attributes["http.response.status_code"] = profile.status if profile.status
        name = "#{profile.method} #{profile.path}".strip

        ScopedIdGenerator.with(trace_id: profile.trace_id, span_id: profile.span_id) do
          tracer.start_span(name, with_parent: parent_context(profile), kind: :server,
                                  attributes: attributes, start_timestamp: started)
        end
      end

      # A caller's span (traceparent) when the request had one, otherwise an empty context, which
      # makes the root span a true root. In both cases the trace_id comes from the generator.
      def parent_context(profile)
        return OpenTelemetry::Context.empty unless profile.parent_span_id

        remote = OpenTelemetry::Trace::SpanContext.new(
          trace_id: [profile.trace_id].pack("H*"), span_id: [profile.parent_span_id].pack("H*"),
          trace_flags: OpenTelemetry::Trace::TraceFlags.from_byte(SAMPLED_FLAG), remote: true
        )
        OpenTelemetry::Trace.context_with_span(OpenTelemetry::Trace.non_recording_span(remote))
      end

      def root_status(root, profile)
        return unless profile.status.to_i >= 500

        root.status = OpenTelemetry::Trace::Status.error("HTTP #{profile.status}")
      end

      def mark_error(span, error)
        span.status = OpenTelemetry::Trace::Status.error(error.to_s) if error
      end

      # Every collected event worth a span, as {name:, kind:, attributes:, started_at:, duration:}
      # (duration in ms). An event without a start time (a profile saved before the collectors
      # recorded it) starts with the request.
      def children(profile)
        data = profile.collectors_data || {}
        sql_spans(fetch(data, "database")) + view_spans(fetch(data, "view")) +
          cache_spans(fetch(data, "cache")) + http_spans(fetch(data, "http"))
      end

      def sql_spans(data)
        list(data, :queries).filter_map do |query|
          next if query[:transaction]

          statement = query[:sql].to_s
          { name: sql_name(statement), kind: :client, started_at: time(query[:started_at]),
            duration: query[:duration],
            attributes: { "db.query.text" => statement, "db.operation.name" => statement[/\A\s*(\w+)/, 1].to_s.upcase } }
        end
      end

      def view_spans(data)
        views = list(data, :views).map { |v| ["render_template", v] } +
                list(data, :partials).map { |v| ["render_partial", v] }
        views.map do |kind, view|
          { name: "#{kind} #{view[:identifier]}", kind: :internal, started_at: time(view[:started_at]),
            duration: view[:duration], attributes: { "code.filepath" => view[:identifier].to_s } }
        end
      end

      # The key is left out: cache keys carry user data, and the dashboard is the place for them.
      def cache_spans(data)
        reads = list(data, :reads).map { |e| ["read", e, { "cache.hit" => e[:hit] ? true : false }] }
        writes = list(data, :writes).map { |e| ["write", e, {}] }
        deletes = list(data, :deletes).map { |e| ["delete", e, {}] }
        (reads + writes + deletes).map do |operation, event, attributes|
          { name: "cache #{operation}", kind: :internal, started_at: time(event[:started_at]),
            duration: event[:duration], attributes: attributes.merge("cache.operation" => operation) }
        end
      end

      # Scheme, host and path only: the query string of an outbound call may hold a token.
      def http_spans(data)
        list(data, :requests).filter_map do |request|
          next if request[:in_flight]

          url = safe_url(request[:url])
          attributes = { "http.request.method" => request[:method].to_s, "url.full" => url }
          attributes["http.response.status_code"] = request[:status] if request[:status].to_i.positive?
          { name: "HTTP #{request[:method]}", kind: :client, started_at: time(request[:started_at]),
            duration: request[:duration], attributes: attributes, error: request[:error] }
        end
      end

      def sql_name(statement)
        operation = statement[/\A\s*(\w+)/, 1].to_s.upcase
        operation.empty? ? "sql" : operation
      end

      def safe_url(url)
        uri = URI.parse(url.to_s)
        uri.query = nil
        uri.fragment = nil
        uri.userinfo = nil
        uri.to_s
      rescue URI::InvalidURIError
        ""
      end

      def fetch(data, key)
        data[key] || data[key.to_sym] || {}
      end

      # A collector's list, whatever the keys' type (symbols as collected, strings once stored).
      def list(data, key)
        Array(data[key] || data[key.to_s]).map { |entry| entry.transform_keys(&:to_sym) }
      end

      def time(value)
        case value
        when Numeric then Time.at(value)
        when String then Time.iso8601(value)
        end
      rescue ArgumentError
        nil
      end
    end
  end
end
