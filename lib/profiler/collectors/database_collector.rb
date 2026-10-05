# frozen_string_literal: true

require_relative "base_collector"
require_relative "../models/sql_query"

module Profiler
  module Collectors
    class DatabaseCollector < BaseCollector
      def initialize(profile)
        super
        @queries = []
        @subscriptions = []
      end

      def icon
        "🗄️"
      end

      def priority
        20
      end

      def tab_config
        {
          key: "database",
          label: "Database",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: true
        }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)

        @subscriptions << subscribe_notification("sql.active_record") do |name, started, finished, unique_id, payload|
          duration = ((finished - started) * 1000).round(2) # milliseconds

          # Skip schema queries and internal Rails queries
          next if payload[:name] == "SCHEMA"
          next if payload[:sql] =~ /^(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i

          query = Models::SqlQuery.new(
            sql: payload[:sql],
            duration: duration,
            binds: extract_binds(payload[:binds]),
            name: payload[:name],
            connection: payload[:connection],
            backtrace: extract_backtrace
          )

          @queries << query
        end
      end

      def collect
        unsubscribe

        data = {
          total_queries: @queries.size,
          total_duration: @queries.sum(&:duration).round(2),
          slow_queries: @queries.select { |q| q.slow?(Profiler.configuration.slow_query_threshold) }.size,
          cached_queries: @queries.count(&:cached?),
          queries: @queries.map(&:to_h)
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
        total = @queries.size
        slow = @queries.select { |q| q.slow?(Profiler.configuration.slow_query_threshold) }.size
        duration = @queries.sum(&:duration).round(2)

        color = if slow > 0
                  "red"
                elsif total > Profiler.configuration.max_queries_warning
                  "orange"
                else
                  "green"
                end

        {
          text: "#{total} queries (#{duration}ms)",
          color: color,
          slow_queries: slow
        }
      end

      private

      def extract_binds(binds)
        return [] unless binds

        binds.map do |bind|
          if bind.respond_to?(:value)
            name = bind.name if bind.respond_to?(:name)
            Profiler::Redaction.filter_named(name, bind.value)
          else
            bind
          end
        end
      rescue StandardError
        # Never let the profiler raise into the application's query.
        binds.map { Profiler::Redaction::MASK }
      end

      def extract_backtrace
        caller_locations(5, 10)
          .reject { |loc| loc.path.include?("active_record") }
          .map { |loc| "#{loc.path}:#{loc.lineno}:in `#{loc.label}`" }
      end
    end
  end
end
