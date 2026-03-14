# frozen_string_literal: true

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
    end
  end
end
