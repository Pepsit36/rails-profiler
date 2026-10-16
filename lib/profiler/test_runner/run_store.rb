# frozen_string_literal: true

require "concurrent"
require "securerandom"
require_relative "../redaction"

module Profiler
  module TestRunner
    # Raised by RunStore#create when as many runs as allowed still have their test process.
    class TooManyRunsError < StandardError; end

    # The runs live in the memory of the process that started them: under a server running
    # several processes (Puma in cluster mode), a run is only known to the worker that started it.
    class RunStore
      TTL = 3600 # 1 hour
      # Finished runs kept at most, the oldest dropped first, on top of the TTL.
      MAX_FINISHED_RUNS = 20

      # signal: the name of the signal that ended the process ("SIGKILL"), nil when it exited.
      Run = Struct.new(:id, :status, :pid, :started_at, :finished_at, :output_lines, :exit_code, :signal, :files, :framework, keyword_init: true) do
        def to_h
          super.merge(
            started_at: started_at&.iso8601,
            finished_at: finished_at&.iso8601,
            output: output_lines.join,
            duration: finished_at && started_at ? ((finished_at - started_at) * 1000).round(2) : nil
          ).except(:output_lines)
        end
      end

      # signaled: the process was ended by a signal that did not come from the profiler (out of
      # memory, a crash, another program), so the tests neither passed nor failed.
      TERMINAL_STATUSES = %w[passed failed killed signaled error].freeze
      NOT_FOUND = { chunks: [].freeze, status: "not_found", position: 0, finished: true }.freeze

      def initialize
        @runs  = Concurrent::Hash.new
        @locks = Concurrent::Hash.new
        @held  = Concurrent::Hash.new
        @output_finished = Concurrent::Hash.new
        @held_lock = Mutex.new
        @output_limits = Concurrent::Hash.new
        @active = Concurrent::Hash.new
        @create_lock = Mutex.new
      end

      # max_active: the run is refused when that many runs still have their test process; a run
      # counts from here until #release. max_output_bytes: what the run keeps of its output (see
      # #keep_output). nil for no limit.
      def create(files:, framework:, max_active: nil, max_output_bytes: nil)
        @create_lock.synchronize do
          if max_active && @active.size >= max_active
            raise TooManyRunsError,
                  "#{@active.size} test runs are already running, the limit is #{max_active} " \
                  "(config.test_runner_max_active_runs). Wait for one to end, or stop it."
          end

          id  = SecureRandom.hex(8)
          run = Run.new(
            id: id,
            status: "pending",
            pid: nil,
            started_at: Time.now,
            finished_at: nil,
            output_lines: Concurrent::Array.new,
            exit_code: nil,
            signal: nil,
            files: files,
            framework: framework.to_s
          )
          cleanup_old_runs
          @runs[id]  = run
          @locks[id] = { mutex: Mutex.new, cond: ConditionVariable.new }
          @active[id] = true
          if max_output_bytes
            tail = max_output_bytes / 4
            @output_limits[id] = { head: max_output_bytes - tail, tail: tail, kept: 0, after_head: 0, end: nil, end_bytes: 0 }
          end
          run
        end
      end

      # The test process of the run ended: it no longer counts against max_active.
      def release(id)
        @active.delete(id)
        nil
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
      #
      # The process is read in binary pieces of a fixed size, so a character can be cut in two
      # as well: its first bytes wait for the next piece the same way. What is shown is UTF-8,
      # with any byte that is not replaced by U+FFFD, so that every reader (JSON of the run, the
      # stream, run_tests) gets text it can encode.
      def append_output(id, chunk)
        run = @runs[id]
        return unless run

        @held_lock.synchronize do
          text = Profiler::Redaction.hide_credentials(@held.fetch(id, "".b) + chunk.to_s.b).b
          holdback = if @output_finished[id]
                       0
                     else
                       [Profiler::Redaction.held_back_bytes(text), incomplete_character_bytes(text)].max
                     end
          cut = text.bytesize - holdback
          @held[id] = text.byteslice(cut, text.bytesize - cut)
          shown = as_text(text.byteslice(0, cut))
          keep_output(id, run, shown) unless shown.empty?
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
          keep_output(id, run, as_text(rest)) if rest && !rest.empty?
          release_tail(id, run)
        end
        signal(id)
      end

      # The output from +position+ on, as it is now, without waiting for more.
      # Returns { chunks: [...], status: "...", position: N, finished: bool }, finished once the
      # status is terminal and the reader of the process has read everything: a killed run gets
      # its status at once, and prints its summary after.
      def read_output(id, position:)
        run = @runs[id]
        return NOT_FOUND unless run

        result = snapshot(run, position)
        result[:finished] &&= @output_finished.fetch(id, false)
        result
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

      # How many bytes at the end of +bytes+ start a UTF-8 character that the next piece ends.
      def incomplete_character_bytes(bytes)
        [3, bytes.bytesize].min.times do |back|
          byte = bytes.getbyte(bytes.bytesize - 1 - back)
          next if byte & 0xC0 == 0x80 # a continuation byte: the start is further back

          length = if byte >= 0xF0 then 4
                   elsif byte >= 0xE0 then 3
                   elsif byte >= 0xC0 then 2
                   else 1
                   end
          return length > back + 1 ? back + 1 : 0
        end
        0
      end

      def as_text(bytes)
        bytes.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # Under a limit, the output is kept as it comes up to the head (the limit less a quarter),
      # then a marker line is shown at once and only the last quarter is kept, in a buffer
      # shown by #release_tail once the process printed everything: the summary of a test run is
      # at its end. Lines only ever get added, so the positions the pages hold stay right.
      # Called under @held_lock.
      def keep_output(id, run, text)
        limit = @output_limits[id]
        return run.output_lines.push(text) unless limit

        unless limit[:end]
          room = limit[:head] - limit[:kept]
          if text.bytesize <= room
            limit[:kept] += text.bytesize
            return run.output_lines.push(text)
          end

          # What fits, without the first bytes of a character the limit cuts in two.
          head = text.byteslice(0, room).scrub("")
          run.output_lines.push(head) unless head.empty?
          run.output_lines.push("\n[Profiler] Output truncated: the run printed more than " \
                                "#{limit[:head]} bytes. The rest is not kept; its last " \
                                "#{limit[:tail]} bytes are shown once the run ends.\n")
          limit[:kept] += head.bytesize
          limit[:end] = []
          text = text.byteslice(head.bytesize, text.bytesize - head.bytesize)
        end

        # The pieces of the end, the oldest dropped while the others hold enough without it.
        limit[:after_head] += text.bytesize
        limit[:end] << text
        limit[:end_bytes] += text.bytesize
        while limit[:end_bytes] - limit[:end].first.bytesize >= limit[:tail]
          limit[:end_bytes] -= limit[:end].shift.bytesize
        end
      end

      # Shows the end kept past the limit, and lets anything appended later (the profiler's own
      # lines about the end of the process) through.
      def release_tail(id, run)
        limit = @output_limits.delete(id)
        return unless limit && limit[:end]

        tail = limit[:end].join
        tail = tail.byteslice(tail.bytesize - limit[:tail], limit[:tail]) if tail.bytesize > limit[:tail]
        # Dropping from the front can leave the last bytes of a character first.
        tail = tail.byteslice(1, tail.bytesize - 1) while !tail.empty? && (tail.getbyte(0) & 0xC0) == 0x80
        left_out = limit[:after_head] - tail.bytesize
        run.output_lines.push("[Profiler] #{left_out} bytes left out. The last #{tail.bytesize} bytes " \
                              "of the output:\n")
        run.output_lines.push(tail.scrub) unless tail.empty?
      end

      def forget(id)
        @runs.delete(id)
        @locks.delete(id)
        @held.delete(id)
        @output_finished.delete(id)
        @output_limits.delete(id)
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

      # Finished runs older than the TTL, and the oldest past MAX_FINISHED_RUNS, are dropped; a
      # run whose process is still there (killed, still printing) is kept whatever its age.
      def cleanup_old_runs
        cutoff = Time.now - TTL
        finished = @runs.values.select { |r| r.finished_at && !@active.key?(r.id) }.sort_by(&:finished_at)
        expired, recent = finished.partition { |r| r.finished_at < cutoff }
        (expired + recent.first([recent.size - MAX_FINISHED_RUNS, 0].max)).each { |r| forget(r.id) }
      end
    end

    def self.run_store
      @run_store ||= RunStore.new
    end
  end
end
