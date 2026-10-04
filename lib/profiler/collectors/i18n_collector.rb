# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module I18nLookupTracker
    def translate(key, **options)
      result = super
      if (collector = Thread.current[:profiler_i18n_collector])
        missing = result.is_a?(String) && result.downcase.include?("translation missing:")
        collector.record_lookup(key, options[:locale] || I18n.locale, result, missing)
      end
      result
    rescue I18n::MissingTranslationData => e
      if (collector = Thread.current[:profiler_i18n_collector])
        collector.record_lookup(key, options[:locale] || I18n.locale, nil, true)
      end
      raise
    end
    alias_method :t, :translate
  end

  module Collectors
    class I18nCollector < BaseCollector
      def initialize(profile)
        super
        @lookups = []
      end

      def icon
        "🌐"
      end

      def priority
        45
      end

      def tab_config
        {
          key: "i18n",
          label: "I18n",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        return unless defined?(I18n)

        unless I18n.singleton_class.ancestors.include?(Profiler::I18nLookupTracker)
          I18n.singleton_class.prepend(Profiler::I18nLookupTracker)
        end

        Thread.current[:profiler_i18n_collector] = self
      end

      def collect
        Thread.current[:profiler_i18n_collector] = nil

        missing_count = @lookups.count { |l| l[:missing] }

        store_data(
          locale: I18n.locale.to_s,
          total: @lookups.size,
          missing_count: missing_count,
          lookups: @lookups
        )
      end

      def record_lookup(key, locale, result, missing = false)
        value = missing ? "[missing]" : truncate(result.to_s)

        @lookups << {
          key: key.to_s,
          locale: locale.to_s,
          value: value,
          missing: missing
        }
      end

      def toolbar_summary
        missing = @lookups.count { |l| l[:missing] }
        locale = I18n.locale.to_s
        total = @lookups.size

        color = missing > 0 ? "red" : "green"

        { text: "#{locale} · #{total} keys", color: color }
      end

      private

      def truncate(str, max = 100)
        Profiler::Redaction.truncate(str, max, "…")
      end
    end
  end
end
