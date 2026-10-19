# frozen_string_literal: true

require "securerandom"

module Profiler
  # The W3C Trace Context `traceparent` header, version 00:
  # `00-{trace-id:32 hex}-{parent-id:16 hex}-{trace-flags:2 hex}`.
  module TraceContext
    HEADER = "traceparent"
    # Version ff is forbidden by the specification; a later version is read by its first four
    # fields, as the specification asks of a parser that does not know it.
    PATTERN = /\A(?<version>\h{2})-(?<trace_id>\h{32})-(?<parent_id>\h{16})-(?<flags>\h{2})(?:-.*)?\z/
    ZERO_TRACE_ID = ("0" * 32).freeze
    ZERO_SPAN_ID = ("0" * 16).freeze

    Parsed = Struct.new(:trace_id, :parent_id, :flags)

    module_function

    # The trace-id, parent-id and flags of a valid header value, nil for anything else.
    def parse(value)
      match = PATTERN.match(value.to_s.strip)
      return nil unless match

      version = match[:version].downcase
      trace_id = match[:trace_id].downcase
      parent_id = match[:parent_id].downcase
      return nil if version == "ff"
      # Version 00 has exactly four fields; the all-zero ids are invalid.
      return nil if version == "00" && value.to_s.strip.count("-") != 3
      return nil if trace_id == ZERO_TRACE_ID || parent_id == ZERO_SPAN_ID

      Parsed.new(trace_id, parent_id, match[:flags].downcase)
    end

    def new_trace_id
      SecureRandom.hex(16)
    end

    def new_span_id
      SecureRandom.hex(8)
    end

    def format(trace_id, span_id, flags = "01")
      "00-#{trace_id}-#{span_id}-#{flags}"
    end
  end
end
