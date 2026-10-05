# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class CacheCollector < BaseCollector
      def initialize(profile)
        super
        @cache_reads = []
        @cache_writes = []
        @cache_deletes = []
        @subscriptions = []
      end

      def icon
        "💾"
      end

      def priority
        50
      end

      def tab_config
        {
          key: "cache",
          label: "Cache",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)

        @subscriptions << subscribe_notification("cache_read.active_support") do |name, started, finished, unique_id, payload|
          duration = ((finished - started) * 1000).round(2)
          @cache_reads << {
            key: payload[:key],
            hit: payload[:hit],
            duration: duration
          }
        end

        @subscriptions << subscribe_notification("cache_write.active_support") do |name, started, finished, unique_id, payload|
          duration = ((finished - started) * 1000).round(2)
          @cache_writes << {
            key: payload[:key],
            duration: duration
          }
        end

        @subscriptions << subscribe_notification("cache_delete.active_support") do |name, started, finished, unique_id, payload|
          duration = ((finished - started) * 1000).round(2)
          @cache_deletes << {
            key: payload[:key],
            duration: duration
          }
        end
      end

      def collect
        unsubscribe

        hits = @cache_reads.count { |r| r[:hit] }
        misses = @cache_reads.count { |r| !r[:hit] }

        data = {
          reads: @cache_reads,
          writes: @cache_writes,
          deletes: @cache_deletes,
          total_reads: @cache_reads.size,
          total_writes: @cache_writes.size,
          total_deletes: @cache_deletes.size,
          hits: hits,
          misses: misses,
          hit_rate: @cache_reads.empty? ? 0 : (hits.to_f / @cache_reads.size * 100).round(2)
        }

        store_data(data)
      end

      # Collect reads only what the collector gathered itself.
      def collect_from_any_thread?
        true
      end

      def unsubscribe
        unsubscribe_notifications(@subscriptions)
      end

      def toolbar_summary
        hits = @cache_reads.count { |r| r[:hit] }
        total = @cache_reads.size

        {
          text: "#{hits}/#{total} hits",
          color: "cyan"
        }
      end
    end
  end
end
