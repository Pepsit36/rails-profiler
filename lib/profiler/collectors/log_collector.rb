# frozen_string_literal: true

require "logger"
require_relative "base_collector"

module Profiler
  module Collectors
    class LogCollector < BaseCollector
      SEVERITY_LABELS = %w[DEBUG INFO WARN ERROR FATAL UNKNOWN].freeze

      class CaptureLogger < ::Logger
        def initialize
          super(File::NULL)
        end

        def add(severity, message = nil, progname = nil)
          msg = message || progname
          msg = yield if block_given? && msg.nil?
          return true if msg.nil?

          Thread.current[:profiler_logs] ||= []
          Thread.current[:profiler_logs] << {
            level: SEVERITY_LABELS[severity] || "UNKNOWN",
            message: msg.to_s.strip,
            timestamp: Time.now.iso8601(3)
          }
          true
        end

        def <<(msg)
          add(0, msg.to_s)
        end
      end

      def icon
        "📋"
      end

      def priority
        18
      end

      def name
        "logs"
      end

      def tab_config
        {
          key: "logs",
          label: "Logs",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        Thread.current[:profiler_logs] = []
        @capture_logger = CaptureLogger.new

        if defined?(Rails) && Rails.logger
          if Rails.logger.respond_to?(:broadcast_to)
            Rails.logger.broadcast_to(@capture_logger)
          elsif defined?(ActiveSupport::Logger)
            Rails.logger.extend(ActiveSupport::Logger.broadcast(@capture_logger))
          end
        end
      rescue => e
        warn "LogCollector#subscribe failed: #{e.message}"
      end

      def collect
        logs = Thread.current[:profiler_logs] || []

        if defined?(Rails) && Rails.logger && @capture_logger
          if Rails.logger.respond_to?(:stop_broadcasting_to)
            Rails.logger.stop_broadcasting_to(@capture_logger)
          end
        end

        Thread.current[:profiler_logs] = []

        errors   = logs.count { |l| %w[ERROR FATAL].include?(l[:level]) }
        warnings = logs.count { |l| l[:level] == "WARN" }

        store_data({
          count: logs.size,
          errors: errors,
          warnings: warnings,
          logs: logs
        })
      end

      def toolbar_summary
        return { text: "0 logs", color: "gray" } if @data.empty?

        count    = @data[:count] || 0
        errors   = @data[:errors] || 0
        warnings = @data[:warnings] || 0

        color = if errors > 0
          "red"
        elsif warnings > 0
          "orange"
        else
          "gray"
        end

        label = if errors > 0
          "#{errors} error#{errors != 1 ? "s" : ""}"
        elsif warnings > 0
          "#{warnings} warning#{warnings != 1 ? "s" : ""}"
        else
          "#{count} log#{count != 1 ? "s" : ""}"
        end

        { text: label, color: color }
      end
    end
  end
end
