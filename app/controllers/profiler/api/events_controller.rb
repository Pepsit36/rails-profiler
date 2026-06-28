# frozen_string_literal: true

module Profiler
  module Api
    class EventsController < Profiler::ApplicationController
      include ActionController::Live
      skip_before_action :verify_authenticity_token

      def subscribe
        response.headers["Content-Type"]      = "text/event-stream"
        response.headers["Cache-Control"]     = "no-cache"
        response.headers["X-Accel-Buffering"] = "no"

        sse = ActionController::Live::SSE.new(response.stream, retry: 3000, event: "profile_update")
        id  = Profiler::SSE.current.subscribe(params[:token], Array(params[:collectors]))

        begin
          loop do
            event = Profiler::SSE.current.wait_for_event(id, timeout: 30)
            if event
              sse.write(event)
            else
              sse.write({}, event: "heartbeat")
            end
          end
        rescue ActionController::Live::ClientDisconnected, IOError
          # Client disconnected — normal exit
        ensure
          Profiler::SSE.current.unsubscribe(id)
          sse.close
        end
      end
    end
  end
end
