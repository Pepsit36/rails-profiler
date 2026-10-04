# frozen_string_literal: true

require "concurrent"
require "securerandom"
require_relative "../redaction"

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

      TERMINAL_STATUSES = %w[passed failed killed error].freeze

      def initialize
        @runs  = Concurrent::Hash.new
        @locks = Concurrent::Hash.new
        @held  = Concurrent::Hash.new
        @held_lock = Mutex.new
      end

      def create(files:, framework:)
        id  = SecureRandom.hex(8)
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
        @runs[id]  = run
        @locks[id] = { mutex: Mutex.new, cond: ConditionVariable.new }
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
        release_held_output(id, run) if TERMINAL_STATUSES.include?(run.status)
        signal(id)
        run
      end

      # Output is free text read back by the API, the SSE stream and run_tests, in the pieces it
      # arrives in: the profiler's own credentials are masked by value, as in a profile. They
      # are masked on the text joined with what was held back from the previous piece, and the
      # last bytes that could start a credential wait for the next piece, so that none is ever
      # shown cut in two. What is held back is released when the run ends.
      def append_output(id, chunk)
        run = @runs[id]
        return unless run

        @held_lock.synchronize do
          holdback = TERMINAL_STATUSES.include?(run.status) ? 0 : Profiler::Redaction.credential_holdback
          text = Profiler::Redaction.hide_credentials(@held.fetch(id, "".b) + chunk.to_s.b)
          cut = [text.bytesize - holdback, 0].max
          @held[id] = text.byteslice(cut, text.bytesize - cut)
          shown = text.byteslice(0, cut).force_encoding(chunk.to_s.encoding)
          run.output_lines.push(shown) unless shown.empty?
        end
        signal(id)
      end

      # Block until new output is available at +position+ or the run terminates.
      # Returns { chunks: [...], status: "...", position: N, finished: bool }.
      def wait_for_output(id, position:, timeout: 10)
        run = @runs[id]
        return { chunks: [], status: "not_found", position: 0, finished: true } unless run

        lock = @locks[id]
        return snapshot(run, position) unless lock

        lock[:mutex].synchronize do
          current = run.output_lines.size
          if current <= position && !TERMINAL_STATUSES.include?(run.status)
            lock[:cond].wait(lock[:mutex], timeout)
          end
        end

        snapshot(run, position)
      end

      def all
        @runs.values.sort_by { |r| r.started_at || Time.at(0) }.reverse
      end

      private

      def signal(id)
        lock = @locks[id]
        return unless lock
        lock[:mutex].synchronize { lock[:cond].broadcast }
      end

      def release_held_output(id, run)
        @held_lock.synchronize do
          rest = @held.delete(id)
          run.output_lines.push(rest) if rest && !rest.empty?
        end
      end

      def snapshot(run, position)
        lines = run.output_lines.dup
        {
          chunks: lines[position..] || [],
          status: run.status,
          position: lines.size,
          finished: TERMINAL_STATUSES.include?(run.status)
        }
      end

      def cleanup_old_runs
        cutoff = Time.now - TTL
        @runs.delete_if { |id, r| r.finished_at && r.finished_at < cutoff && @locks.delete(id) && (@held.delete(id) || true) }
      end
    end

    def self.run_store
      @run_store ||= RunStore.new
    end
  end
end
