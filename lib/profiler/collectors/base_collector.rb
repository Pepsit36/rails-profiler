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

      # Clears a thread-local slot this collector set to itself, but not one a nested profile
      # (a job performed inline during a request) has taken over since.
      def release_thread_slot(key)
        Thread.current[key] = nil if Thread.current[key].equal?(self)
      end

      def unsubscribe_notifications(subscriptions)
        return unless defined?(ActiveSupport::Notifications)

        subscriptions.each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }
        subscriptions.clear
      end
    end
  end
end
