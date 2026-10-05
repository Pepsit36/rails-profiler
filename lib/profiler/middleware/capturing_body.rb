# frozen_string_literal: true

require_relative "../redaction"
require_relative "../current_context"

module Profiler
  module Middleware
    # The body a streamed response leaves the profiler with: it hands the server each chunk as
    # the application yields it, keeps a copy up to a byte limit, and finishes the profile when
    # the server closes it. It answers to_path when the application's body does, so a file can
    # still be sent by its path, and never to_ary, so nothing above it buffers the stream.
    #
    # An error raised while the application's body is iterated goes on to the server, which
    # knows what to do with it; it is only noted for the profile. One raised by the server
    # itself in the block (the client went away) is the server's, not the application's.
    class CapturingBody
      # on_close receives the captured bytes, the size of the body seen so far, whether the
      # body was iterated to its end (if not, the size is only a minimum), and the
      # application's error if there was one. It runs once, after the body has been closed.
      #
      # While the server iterates the body, its thread carries the profile's token
      # (CurrentContext), as the request's thread did: what the body does then, a template
      # streamed by `render stream: true` for one, belongs to this profile.
      def initialize(body, limit:, token: nil, &on_close)
        @body = body
        @limit = limit
        @token = token
        @on_close = on_close
        @complete = false
        @captured = String.new(encoding: Encoding::BINARY)
        @encoding = nil
        @size = 0
        @error = nil
        @closed = false
      end

      def each
        previous_token = CurrentContext.token
        CurrentContext.token = @token if @token
        begin
          @body.each do |chunk|
            capture(chunk)
            begin
              yield chunk
            rescue Exception => e # rubocop:disable Lint/RescueException
              @server_error = e
              raise
            end
          end
          @complete = true
        rescue => e
          @error ||= e unless e.equal?(@server_error)
          raise
        ensure
          CurrentContext.token = previous_token
        end
      end

      def to_path
        @body.to_path
      end

      def respond_to?(name, include_all = false)
        return @body.respond_to?(name, include_all) if name.to_sym == :to_path

        super
      end

      def close
        return if @closed

        @closed = true
        begin
          @body.close if @body.respond_to?(:close)
        ensure
          @on_close.call(captured, @size, @complete, @error)
        end
      end

      # The server left the body without closing it: the profile is finished with what was
      # captured, and the application's body is left to whoever holds it.
      def abandon
        return if @closed

        @closed = true
        @on_close.call(captured, @size, @complete, @error)
      end

      def closed?
        @closed
      end

      private

      def capture(chunk)
        chunk = chunk.to_s
        @encoding ||= chunk.encoding
        @size += chunk.bytesize
        # One byte past the limit, so that Redaction.cut_bytes knows the body goes on.
        room = @limit ? @limit + 1 - @captured.bytesize : chunk.bytesize
        @captured << chunk.byteslice(0, room).b if room.positive?
      end

      def captured
        text = @captured.dup.force_encoding(@encoding || Encoding::UTF_8)
        @limit ? Redaction.cut_bytes(text, @limit) : text
      end
    end
  end
end
