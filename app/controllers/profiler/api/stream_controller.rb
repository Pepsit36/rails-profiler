# frozen_string_literal: true

module Profiler
  module Api
    # Server-sent events: tells a client which of the profiles it follows changed, as it happens
    # (see Profiler::Live::EventStream). One request is one open stream, so it holds a server
    # thread: Profiler::Live::Streams caps them, a Puma with too few threads is refused, and the
    # client falls back to asking Api::EventsController when this answers 503.
    class StreamController < Profiler::ApplicationController
      MAX_TOKENS = 20
      # A stream must leave threads to the application itself.
      MIN_SPARE_THREADS = 2

      def show
        return unavailable("live events are off") unless Profiler.configuration.live_events
        # A HEAD gets the headers only: the server drops its body without iterating or closing it.
        return head(:ok, content_type: "text/event-stream") if request.head?
        return unavailable("the profiler storage is unavailable") if Profiler.storage.is_a?(Profiler::Storage::Unavailable)

        tokens = params[:tokens].to_s.split(",").uniq.select { |t| Profiler::Storage::Token.valid?(t) }.first(MAX_TOKENS)
        return render(json: { error: "tokens is required" }, status: :bad_request) if tokens.empty?

        limit = stream_limit
        return unavailable("this server has too few threads for a live stream") if limit < 1
        lease = Profiler::Live::Streams.acquire(limit)
        return unavailable("too many open streams") unless lease

        begin
          response.headers["Content-Type"] = "text/event-stream"
          response.headers["Cache-Control"] = "no-cache"
          response.headers["X-Accel-Buffering"] = "no"
          # Rack::ETag reads a body that answers to_ary whole to digest it, unless the response already
          # carries an ETag or a Last-Modified: on Rails 7 that would hold the stream back until it
          # ends. A stream has neither a digest nor a date worth anything, this only says so.
          response.headers["Last-Modified"] = Time.now.httpdate
          self.response_body = Profiler::Live::EventStream.new(
            storage: Profiler.storage, tokens: tokens, lease: lease, cursors: cursors
          )
        rescue StandardError
          Profiler::Live::Streams.release(lease)
          raise
        end
      end

      private

      def unavailable(reason)
        response.headers["Retry-After"] = "30"
        render json: { error: reason }, status: :service_unavailable
      end

      # since=token:cursor,token:cursor
      def cursors
        params[:since].to_s.split(",").to_h do |pair|
          token, cursor = pair.split(":", 2)
          [token, cursor.to_s[0, 40]]
        end
      end

      # The configured cap, lowered so that the application keeps MIN_SPARE_THREADS threads when
      # Puma says how many it has.
      def stream_limit
        limit = Profiler.configuration.live_events_max_streams.to_i
        max_threads = begin
          request.env["puma.config"]&.options&.[](:max_threads)
        rescue StandardError
          nil
        end
        max_threads ? [limit, max_threads.to_i - MIN_SPARE_THREADS].min : limit
      end
    end
  end
end
