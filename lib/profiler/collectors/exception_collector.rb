# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class ExceptionCollector < BaseCollector
      def icon
        "💥"
      end

      def priority
        5
      end

      def name
        "exception"
      end

      def tab_config
        {
          key: "exception",
          label: "Exception",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        @exception_data = nil

        @subscriptions = [
          subscribe_notification("process_action.action_controller") do |_name, _started, _finished, _id, payload|
            ex = payload[:exception_object]
            capture_exception(ex) if ex && @exception_data.nil?
          end
        ]
      end

      def capture(ex)
        capture_exception(ex) if ex && @exception_data.nil?
      end

      def collect
        unsubscribe

        store_data(@exception_data || {})
      end

      # Collect reads only what the collector gathered itself.
      def collect_from_any_thread?
        true
      end

      def unsubscribe
        unsubscribe_notifications(@subscriptions) if @subscriptions
      end

      def has_data?
        !@exception_data.nil? && !@exception_data.empty?
      end

      def toolbar_summary
        return { text: "", color: "gray" } unless has_data?

        { text: @exception_data[:exception_class], color: "red" }
      end

      private

      def capture_exception(ex)
        raw_backtrace = ex.backtrace || []

        cleaned = if defined?(Rails) && Rails.respond_to?(:backtrace_cleaner)
          Rails.backtrace_cleaner.clean(raw_backtrace)
        else
          raw_backtrace.first(30)
        end

        # Fall back to raw if cleaner returned nothing
        cleaned = raw_backtrace.first(30) if cleaned.empty?

        backtrace = cleaned.map do |line|
          {
            location: line,
            app_frame: app_frame?(line)
          }
        end

        @exception_data = {
          exception_class: ex.class.name,
          message: ex.message.to_s,
          backtrace: backtrace
        }
      end

      def app_frame?(line)
        return false if line.include?("/gems/")
        return false if line.match?(%r{/ruby/\d+\.\d+\.\d+/})
        return false if line.include?("vendor/bundle")
        true
      end
    end
  end
end
