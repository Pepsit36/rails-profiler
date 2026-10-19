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

    def self.clear
      Thread.current[:profiler_token] = nil
      Thread.current[:profiler_trace_id] = nil
    end
  end
end
