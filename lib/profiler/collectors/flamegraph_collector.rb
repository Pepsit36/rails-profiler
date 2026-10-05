# frozen_string_literal: true

require_relative "base_collector"
require_relative "../models/timeline_event"

module Profiler
  module Collectors
    class FlameGraphCollector < BaseCollector
      def initialize(profile)
        super
        @events = []
        @subscriptions = []
        @mutex = Mutex.new
      end

      def icon
        "🔥"
      end

      def priority
        30
      end

      def tab_config
        {
          key: "flamegraph",
          label: "Flame Graph",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)

        claim_thread_slot(:profiler_flamegraph_collector, self)

        # Controller action
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("process_action.action_controller") do |_name, started, finished, _unique_id, payload|
          add_event Models::TimelineEvent.new(
            name: "#{payload[:controller]}##{payload[:action]}",
            started_at: started,
            finished_at: finished,
            category: "controller",
            payload: {
              controller: payload[:controller],
              action: payload[:action],
              format: payload[:format],
              method: payload[:method],
              path: payload[:path],
              status: payload[:status]
            }
          )
        end

        # Template rendering
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("render_template.action_view") do |_name, started, finished, _unique_id, payload|
          identifier = short_identifier(payload[:identifier])
          add_event Models::TimelineEvent.new(
            name: "Render: #{identifier}",
            started_at: started,
            finished_at: finished,
            category: "view",
            payload: { identifier: identifier, layout: payload[:layout] }
          )
        end

        # Partial rendering
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("render_partial.action_view") do |_name, started, finished, _unique_id, payload|
          identifier = short_identifier(payload[:identifier])
          add_event Models::TimelineEvent.new(
            name: "Partial: #{identifier}",
            started_at: started,
            finished_at: finished,
            category: "partial",
            payload: { identifier: identifier }
          )
        end

        # SQL queries
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") do |_name, started, finished, _unique_id, payload|
          next if payload[:name] == "SCHEMA"
          next if payload[:sql] =~ /^(BEGIN|COMMIT|ROLLBACK|SAVEPOINT)/i

          sql = payload[:sql].to_s
          add_event Models::TimelineEvent.new(
            name: Profiler::Redaction.truncate(sql, 80),
            started_at: started,
            finished_at: finished,
            category: "sql",
            payload: { sql: sql, name: payload[:name] }
          )
        end

        # Cache operations
        %w[cache_read.active_support cache_write.active_support cache_delete.active_support].each do |event_name|
          @subscriptions << ActiveSupport::Notifications.monotonic_subscribe(event_name) do |name, started, finished, _unique_id, payload|
            op = name.split(".").first.sub("cache_", "")
            key = payload[:key].to_s
            add_event Models::TimelineEvent.new(
              name: "cache_#{op}: #{Profiler::Redaction.truncate(key, 60)}",
              started_at: started,
              finished_at: finished,
              category: "cache",
              payload: { operation: op, key: key, hit: payload[:hit] }
            )
          end
        end
      end

      # Called by Profiler.measure to record custom instrumentation events
      def record_custom_event(label:, started_at:, finished_at:, metadata: {})
        add_event Models::TimelineEvent.new(
          name: label,
          started_at: started_at,
          finished_at: finished_at,
          category: "custom",
          payload: metadata
        )
      end

      # Called by NetHttpInstrumentation to record outbound HTTP events
      def record_http_event(started_at:, finished_at:, url:, method:, status:)
        add_event Models::TimelineEvent.new(
          name: "HTTP #{method} #{url}",
          started_at: started_at,
          finished_at: finished_at,
          category: "http",
          payload: { url: url, method: method, status: status }
        )
      end

      def collect
        unsubscribe

        root_events = build_hierarchy(@events)

        store_data({
          total_events: @events.size,
          total_duration: @events.empty? ? 0 : @events.map(&:duration).sum.round(2),
          root_events: root_events.map(&:to_h)
        })
      end

      # Collect reads only what the collector gathered itself.
      def collect_from_any_thread?
        true
      end

      def unsubscribe
        unsubscribe_notifications(@subscriptions)
        restore_thread_slots
      end

      def toolbar_summary
        {
          text: "#{@events.size} events",
          color: "blue"
        }
      end

      private

      def build_hierarchy(events)
        return [] if events.empty?

        # Sort by started_at ASC, then by duration DESC (longest first = parents first)
        sorted = events.sort_by { |e| [e.started_at, -e.duration] }

        # Stack-based nesting: each stack entry is a potential parent
        roots = []
        stack = []

        sorted.each do |event|
          # Pop stack entries that have finished before this event starts
          stack.pop while stack.any? && stack.last.finished_at <= event.started_at

          # Pop stack entries where this event doesn't fit inside
          stack.pop while stack.any? && event.finished_at > stack.last.finished_at

          if stack.any?
            stack.last.add_child(event)
          else
            roots << event
          end

          stack.push(event)
        end

        roots
      end

      def add_event(event)
        @mutex.synchronize { @events << event }
      end

      def short_identifier(identifier)
        return identifier.to_s unless identifier.to_s.include?("/")

        parts = identifier.to_s.split("/")
        parts.last(2).join("/")
      end
    end
  end
end
