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
      NOT_FOUND = { chunks: [].freeze, status: "not_found", position: 0, finished: true }.freeze

      def initialize
        @runs  = Concurrent::Hash.new
        @locks = Concurrent::Hash.new
        @held  = Concurrent::Hash.new
        @output_finished = Concurrent::Hash.new
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
        signal(id)
        run
      end

      # Output is free text read back by the API, the SSE stream and run_tests, in the pieces it
      # arrives in: the profiler's own credentials are masked by value, as in a profile. They
      # are masked on the text joined with what was held back from the previous piece, and the
      # last bytes that could start a credential wait for the next piece, so that none is ever
      # shown cut in two. What is held back is released by finish_output, once the process has
      # nothing more to print: a killed run still prints its summary after its status changed.
      def append_output(id, chunk)
        run = @runs[id]
        return unless run

        @held_lock.synchronize do
          text = Profiler::Redaction.hide_credentials(@held.fetch(id, "".b) + chunk.to_s.b)
          holdback = @output_finished[id] ? 0 : Profiler::Redaction.held_back_bytes(text)
          cut = text.bytesize - holdback
          @held[id] = text.byteslice(cut, text.bytesize - cut)
          shown = text.byteslice(0, cut).force_encoding(chunk.to_s.encoding)
          run.output_lines.push(shown) unless shown.empty?
        end
        signal(id)
      end

      # The end of the output, told by the reader of the process once it read everything: the
      # bytes held back are shown, and anything appended later is shown as it comes.
      def finish_output(id)
        run = @runs[id]
        return unless run

        @held_lock.synchronize do
          @output_finished[id] = true
          rest = @held.delete(id)
          run.output_lines.push(rest) if rest && !rest.empty?
        end
        signal(id)
      end

      # The output from +position+ on, as it is now, without waiting for more.
      # Returns { chunks: [...], status: "...", position: N, finished: bool }.
      def read_output(id, position:)
        run = @runs[id]
        return NOT_FOUND unless run

        snapshot(run, position)
      end

      # Block until new output is available at +position+ or the run terminates.
      # Returns the same as read_output.
      def wait_for_output(id, position:, timeout: 10)
        run = @runs[id]
        return NOT_FOUND unless run

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

      def forget_output(id)
        @held.delete(id)
        @output_finished.delete(id)
        true
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
        @runs.delete_if { |id, r| r.finished_at && r.finished_at < cutoff && @locks.delete(id) && forget_output(id) }
      end
    end

    def self.run_store
      @run_store ||= RunStore.new
    end
  end
end
