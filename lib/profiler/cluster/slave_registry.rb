# frozen_string_literal: true

require "concurrent-ruby"

module Profiler
  module Cluster
    class SlaveRegistry
      Entry = Struct.new(:name, :url, :registered_at, :last_heartbeat_at, keyword_init: true) do
        def status
          threshold = Profiler.configuration.cluster_offline_threshold
          (Time.now - last_heartbeat_at) < threshold ? "online" : "offline"
        end

        def to_h
          super.merge(status: status).tap do |h|
            h[:registered_at] = h[:registered_at]&.iso8601
            h[:last_heartbeat_at] = h[:last_heartbeat_at]&.iso8601
          end
        end
      end

      def initialize
        @slaves = Concurrent::Hash.new
      end

      def register(name:, url:)
        now = Time.now
        if (existing = @slaves[name])
          existing.url = url
          existing.last_heartbeat_at = now
        else
          @slaves[name] = Entry.new(name: name, url: url, registered_at: now, last_heartbeat_at: now)
        end
        @slaves[name]
      end

      def heartbeat(name)
        @slaves[name]&.tap { |e| e.last_heartbeat_at = Time.now }
      end

      def find!(name)
        @slaves[name] || raise(Profiler::Error, "Unknown slave profiler: #{name}")
      end

      def all
        @slaves.values.map(&:to_h)
      end

      def online_names
        @slaves.select { |_, entry| entry.status == "online" }.keys
      end
    end
  end
end
