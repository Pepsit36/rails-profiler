# frozen_string_literal: true

module Profiler
  module Api
    # Tells the toolbar whether its profile was saved again since the version it holds. Answered
    # at once: the toolbar asks again later, so no server thread waits for a save that may never
    # come, however many pages are open.
    class EventsController < Profiler::ApplicationController
      def show
        since = params[:since].to_i
        cursor = Profiler::SSE.current.version(params[:token])

        render json: { cursor: [cursor, since].max, updated: cursor > since }
      end
    end
  end
end
