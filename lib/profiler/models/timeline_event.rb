# frozen_string_literal: true

module Profiler
  module Models
    class TimelineEvent
      attr_reader :name, :started_at, :finished_at, :duration, :payload, :children

      def initialize(name:, started_at:, finished_at:, payload: {})
        @name = name
        @started_at = started_at
        @finished_at = finished_at
        @duration = ((finished_at - started_at) * 1000).round(2) # milliseconds
        @payload = payload
        @children = []
      end

      def add_child(event)
        @children << event
      end

      def to_h
        {
          name: @name,
          started_at: @started_at,
          finished_at: @finished_at,
          duration: @duration,
          payload: @payload,
          children: @children.map(&:to_h)
        }
      end

      def to_json(*args)
        to_h.to_json(*args)
      end
    end
  end
end
