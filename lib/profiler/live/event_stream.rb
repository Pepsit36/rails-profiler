# frozen_string_literal: true

require "json"
require_relative "signature"
require_relative "streams"

module Profiler
  module Live
    # The body of GET /_profiler/api/stream: a text/event-stream that says which of the profiles it
    # was given changed, as it happens. It answers to a cursor per profile (Signature): a profile
    # whose cursor is not the current one is announced at once, so a client reconnecting misses
    # nothing. The thread serving it sleeps between checks, which is why Streams caps them.
    #
    # The storage is only read when its live_marker moved (a save, from any process), plus a full
    # check every FULL_CHECK_TICKS as a safety net.
    class EventStream
      LIFETIME = 300
      TICK = 1.0
      HEARTBEAT = 15
      FULL_CHECK_TICKS = 10

      def initialize(storage:, tokens:, cursors: {}, lifetime: LIFETIME, tick: TICK)
        @storage = storage
        @tokens = tokens
        @cursors = cursors.dup
        @lifetime = lifetime
        @tick = tick
        @released = false
        @mutex = Mutex.new
      end

      def each
        yield "retry: 3000\n: ready\n\n"
        started = clock
        last_beat = started
        last_marker = nil
        ticks = 0
        loop do
          marker = @storage.live_marker
          if marker != last_marker || (ticks % FULL_CHECK_TICKS).zero?
            last_marker = marker
            changed.each { |frame| yield frame }
          end
          ticks += 1
          break if clock - started >= @lifetime

          sleep @tick
          if clock - last_beat >= HEARTBEAT
            yield ": ping\n\n"
            last_beat = clock
          end
        end
        yield "event: end\ndata: {}\n\n"
      rescue StandardError => e
        # A closed connection ends the stream; anything else is worth a line in the log.
        Profiler.log_error_once(:live_stream, "Live::EventStream: stopped", e) unless e.is_a?(IOError) || e.is_a?(SystemCallError)
      ensure
        release
      end

      def close
        release
      end

      private

      def changed
        @tokens.filter_map do |token|
          signature = Signature.of(@storage, token)
          next if @cursors[token] == signature

          @cursors[token] = signature
          "event: update\ndata: #{JSON.generate(token: token, cursor: signature)}\n\n"
        end
      end

      def release
        first = @mutex.synchronize { !@released && (@released = true) }
        Streams.release if first
      end

      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
