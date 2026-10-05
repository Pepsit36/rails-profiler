# frozen_string_literal: true

require "logger"
require_relative "base_collector"

module Profiler
  module Collectors
    class LogCollector < BaseCollector
      SEVERITY_LABELS = %w[DEBUG INFO WARN ERROR FATAL UNKNOWN].freeze

      # Records into the thread's buffer, which only exists while a LogCollector of this thread
      # is subscribed: lines logged by other threads, or after release, are not kept. A logger
      # bound to one collector's buffer records only while that buffer is the thread's current
      # one, so a job performed inline during a request does not log twice into the job.
      class CaptureLogger < ::Logger
        def initialize(buffer = nil)
          super(File::NULL)
          @buffer = buffer
        end

        def add(severity, message = nil, progname = nil)
          logs = Thread.current[:profiler_logs]
          return true unless logs
          return true if @buffer && !logs.equal?(@buffer)

          msg = message || progname
          msg = yield if block_given? && msg.nil?
          return true if msg.nil?

          logs << {
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

      # Rails 7.0 broadcasts by extending the logger with a module, which cannot be taken off
      # again: the logger gets one shared CaptureLogger, once, instead of one per request.
      LEGACY_CAPTURE_LOGGER = CaptureLogger.new
      LEGACY_BROADCAST_MUTEX = Mutex.new

      def self.attach_legacy_broadcast(logger)
        LEGACY_BROADCAST_MUTEX.synchronize do
          return if logger.instance_variable_get(:@profiler_capture_attached)

          logger.extend(ActiveSupport::Logger.broadcast(LEGACY_CAPTURE_LOGGER))
          logger.instance_variable_set(:@profiler_capture_attached, true)
        end
      end

      def subscribe
        @logs = claim_thread_slot(:profiler_logs, [])

        if defined?(Rails) && Rails.logger
          if Rails.logger.respond_to?(:broadcast_to)
            @capture_logger = CaptureLogger.new(@logs)
            @broadcaster = Rails.logger
            @broadcaster.broadcast_to(@capture_logger)
          elsif defined?(ActiveSupport::Logger) && ActiveSupport::Logger.respond_to?(:broadcast)
            self.class.attach_legacy_broadcast(Rails.logger)
          end
        end
      rescue => e
        warn "LogCollector#subscribe failed: #{e.message}"
      end

      # Collect reads only what the collector gathered itself.
      def collect_from_any_thread?
        true
      end

      def unsubscribe
        if @capture_logger
          @broadcaster.stop_broadcasting_to(@capture_logger) if @broadcaster.respond_to?(:stop_broadcasting_to)
          @capture_logger = nil
          @broadcaster = nil
        end
        restore_thread_slots
      end

      def collect
        logs = @logs || Thread.current[:profiler_logs] || []
        unsubscribe

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
