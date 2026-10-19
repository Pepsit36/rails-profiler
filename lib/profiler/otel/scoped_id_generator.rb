# frozen_string_literal: true

module Profiler
  module Otel
    # An id generator for an OpenTelemetry SDK tracer provider that hands out the trace-id and
    # span-id the current thread asked for once (+with+), and otherwise defers to the generator
    # the provider had. This is how a span gets the ids the profile already carries, through the
    # SDK's public API only. Wraps nothing from OpenTelemetry at load time.
    class ScopedIdGenerator
      TRACE_KEY = :profiler_otel_trace_id
      SPAN_KEY = :profiler_otel_span_id

      def initialize(inner)
        @inner = inner
      end

      attr_reader :inner

      # Hex ids (32 and 16 characters) in, the byte strings the SDK uses out.
      def self.with(trace_id:, span_id:)
        Thread.current[TRACE_KEY] = [trace_id].pack("H*") if trace_id
        Thread.current[SPAN_KEY] = [span_id].pack("H*") if span_id
        yield
      ensure
        Thread.current[TRACE_KEY] = nil
        Thread.current[SPAN_KEY] = nil
      end

      def generate_trace_id
        take(TRACE_KEY) || @inner.generate_trace_id
      end

      def generate_span_id
        take(SPAN_KEY) || @inner.generate_span_id
      end

      private

      def take(key)
        value = Thread.current[key]
        Thread.current[key] = nil
        value
      end
    end
  end
end
