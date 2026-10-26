# frozen_string_literal: true

module Profiler
  module CurrentContext
    def self.token
      Thread.current[:profiler_token]
    end

    def self.token=(value)
      Thread.current[:profiler_token] = value
    end

    # The trace id of the profile in progress, for the outgoing calls to carry.
    def self.trace_id
      Thread.current[:profiler_trace_id]
    end

    def self.trace_id=(value)
      Thread.current[:profiler_trace_id] = value
    end

    # The span id of the profile in progress, for the outgoing calls to carry as parent.
    def self.span_id
      Thread.current[:profiler_span_id]
    end

    def self.span_id=(value)
      Thread.current[:profiler_span_id] = value
    end

    # The trace flags from the incoming request (if any) to propagate outward.
    def self.trace_flags
      Thread.current[:profiler_trace_flags]
    end

    def self.trace_flags=(value)
      Thread.current[:profiler_trace_flags] = value
    end

    def self.clear
      Thread.current[:profiler_token] = nil
      Thread.current[:profiler_trace_id] = nil
      Thread.current[:profiler_span_id] = nil
      Thread.current[:profiler_trace_flags] = nil
    end
  end
end
