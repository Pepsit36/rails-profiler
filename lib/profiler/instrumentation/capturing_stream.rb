# frozen_string_literal: true

module Profiler
  module Instrumentation
    # Only the methods the original has are defined: IO.copy_stream picks readpartial over
    # read when it finds it, and Net::HTTP rewinds a stream only if it can.
    module Partial
      def readpartial(*args)
        result = @original.readpartial(*args)
        record(result, false)
        result
      rescue EOFError
        @finished = true
        raise
      end

      def read_nonblock(*args, **opts)
        result = @original.read_nonblock(*args, **opts)
        record(result, false) if result.is_a?(String)
        result
      rescue EOFError
        @finished = true
        raise
      end
    end

    module Rewindable
      # Net::HTTP rewinds a stream before it retries an idempotent request: what was copied
      # belongs to the attempt that failed.
      def rewind(*args)
        result = @original.rewind(*args)
        @buffer.clear
        @total_read = 0
        @finished = false
        result
      end
    end

    # Stands in for a request body_stream that cannot be rewound (a pipe, a socket, a payload
    # object such as RestClient's) while Net::HTTP sends it. It hands every read to the original
    # stream untouched and copies what came out, up to one byte past +limit+, into a buffer; nothing is
    # read ahead, so the server gets exactly the bytes it would have got.
    #
    # to_io and to_path are deliberately not forwarded: IO.copy_stream would use them to go around
    # this object and read the original directly.
    class CapturingStream
      attr_reader :original, :total_read

      def initialize(original, limit)
        @original = original
        @limit = limit
        @buffer = String.new(encoding: Encoding::BINARY)
        @total_read = 0
        @finished = false
        extend Partial if original.respond_to?(:readpartial)
        extend Rewindable if original.respond_to?(:rewind)
      end

      # The bytes seen so far, at most one past +limit+ (so that the caller can tell the body was
      # cut, and cut it with Redaction.cut_bytes, which holds back what could start a credential).
      def captured
        @buffer.dup
      end

      # True once a read has reported the end of the stream.
      def finished?
        @finished
      end

      def read(*args)
        result = @original.read(*args)
        record(result, args.first.nil?)
        result
      end

      def respond_to_missing?(name, include_private = false)
        return false if %i[to_io to_path].include?(name)

        @original.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **opts, &block)
        if %i[to_io to_path].include?(name) || !@original.respond_to?(name)
          return super
        end

        opts.empty? ? @original.public_send(name, *args, &block) : @original.public_send(name, *args, **opts, &block)
      end

      private

      # +whole+: a read without a length, which returns the rest and so ends the stream.
      def record(chunk, whole)
        @finished = true if chunk.nil? || whole
        return if chunk.nil? || chunk.empty?

        @total_read += chunk.bytesize
        room = @limit ? @limit + 1 - @buffer.bytesize : chunk.bytesize
        @buffer << chunk.byteslice(0, room).b if room.positive?
      end
    end
  end
end
