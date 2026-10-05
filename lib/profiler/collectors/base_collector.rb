# frozen_string_literal: true

require_relative "../redaction"
require_relative "lifecycle"

module Profiler
  module Collectors
    class BaseCollector
      attr_reader :profile

      def initialize(profile)
        @profile = profile
        @data = {}
      end

      def name
        self.class.name.split("::").last.gsub("Collector", "").downcase
      end

      def icon
        "📊"
      end

      def priority
        100
      end

      # Tab configuration for dynamic tab system
      def tab_config
        {
          key: name,
          label: name.capitalize,
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      # How to render the tab: :auto (use JSON), :custom (call render_html), :client (frontend renderer)
      def render_mode
        :auto
      end

      # For custom HTML rendering from backend (when render_mode is :custom)
      def render_html(profile)
        nil
      end

      # Whether this collector has data for the current profile
      def has_data?
        data = panel_content
        return false if data.nil?
        return false if data.is_a?(Hash) && data.empty?
        return false if data.is_a?(Array) && data.empty?
        true
      end

      def subscribe
        # Override in subclasses to subscribe to ActiveSupport::Notifications
      end

      # Releases whatever subscribe installed: notification subscribers, samplers, log sinks,
      # thread-local slots. Called after collect, and on every path where collect never runs,
      # so it has to be idempotent and safe when subscribe failed part way or never ran.
      def unsubscribe
        # Override in subclasses that install something in subscribe
      end

      def collect
        # Override in subclasses to collect data
      end

      # Whether collect reads nothing from the request's thread (thread-local slots, the
      # locale): only then can a streamed response keep the collector subscribed until the
      # server closes its body, and collect it from whichever thread closes it. The default
      # is the safe answer: collected on the request's thread when the application returns.
      def collect_from_any_thread?
        false
      end

      # Gives back the thread-local slots subscribe took over, and nothing else: a streamed
      # response does this on the request's thread when the application returns, and keeps the
      # notification subscriptions until its body is closed. Idempotent, like unsubscribe.
      def release_thread_slots
        restore_thread_slots
      end

      # Puts the slots subscribe claimed back, for a while, on the thread (or fiber) that
      # iterates a streamed body: the logs, outbound HTTP calls and measures it makes belong to
      # this profile. Returns what the slots held there, for return_thread_slots.
      def lend_thread_slots
        (@thread_slot_values || {}).to_h do |key, value|
          previous = Thread.current[key]
          Thread.current[key] = value
          [key, previous]
        end
      end

      def return_thread_slots(previous)
        previous&.each { |key, value| Thread.current[key] = value }
      end

      def toolbar_summary
        # Override in subclasses to provide summary for toolbar
        ""
      end

      def panel_content
        # Override in subclasses to provide full panel content
        @data
      end

      def self.inherited(subclass)
        super
        # Auto-register collectors
        (@descendants ||= []) << subclass
      end

      def self.descendants
        @descendants || []
      end

      protected

      def store_data(data)
        @data = data
        @profile.add_collector_data(name, data)
      end

      # Thread-local slots follow a stack: subscribe takes one over and remembers what it held,
      # unsubscribe hands it back. A job performed inline during a request thus records into
      # its own slots, and the request gets its own back, with what it recorded before the job.
      def claim_thread_slot(key, value)
        @claimed_thread_slots ||= {}
        @claimed_thread_slots[key] = Thread.current[key] unless @claimed_thread_slots.key?(key)
        (@thread_slot_values ||= {})[key] = value
        Thread.current[key] = value
      end

      def restore_thread_slots
        @claimed_thread_slots&.each { |key, previous| Thread.current[key] = previous }
        @claimed_thread_slots = nil
      end

      def unsubscribe_notifications(subscriptions)
        return unless defined?(ActiveSupport::Notifications)

        subscriptions.each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }
        subscriptions.clear
      end
    end
  end
end
