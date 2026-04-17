# frozen_string_literal: true

require "concurrent"
require "securerandom"

module Profiler
  module TestRunner
    class RunStore
      TTL = 3600 # 1 hour

      Run = Struct.new(:id, :status, :pid, :started_at, :finished_at, :output_lines, :exit_code, :files, :framework, keyword_init: true) do
        def to_h
          super.merge(
            started_at: started_at&.iso8601,
            finished_at: finished_at&.iso8601,
            output: output_lines.join,
            duration: finished_at && started_at ? ((finished_at - started_at) * 1000).round(2) : nil
          ).except(:output_lines)
        end
      end

      def initialize
        @runs = Concurrent::Hash.new
        @mutex = Mutex.new
      end

      def create(files:, framework:)
        id = SecureRandom.hex(8)
        run = Run.new(
          id: id,
          status: "pending",
          pid: nil,
          started_at: Time.now,
          finished_at: nil,
          output_lines: Concurrent::Array.new,
          exit_code: nil,
          files: files,
          framework: framework.to_s
        )
        @runs[id] = run
        cleanup_old_runs
        run
      end

      def find(id)
        @runs[id]
      end

      def update(id, **attrs)
        run = @runs[id]
        return unless run

        attrs.each { |k, v| run.send(:"#{k}=", v) }
        run
      end

      def append_output(id, chunk)
        run = @runs[id]
        run&.output_lines&.push(chunk)
      end

      def all
        @runs.values.sort_by { |r| r.started_at || Time.at(0) }.reverse
      end

      private

      def cleanup_old_runs
        cutoff = Time.now - TTL
        @runs.delete_if { |_, r| r.finished_at && r.finished_at < cutoff }
      end
    end

    def self.run_store
      @run_store ||= RunStore.new
    end
  end
end
