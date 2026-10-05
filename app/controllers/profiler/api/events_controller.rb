# frozen_string_literal: true

module Profiler
  module Api
    # Tells the toolbar whether its profile was saved again since the version it holds. Answered
    # at once: the toolbar asks again later, so no server thread waits for a save that may never
    # come, however many pages are open.
    class EventsController < Profiler::ApplicationController
      VERSION_FORMAT = /\A\d+\z/

      def show
        cursor = Profiler::SSE.current.version(params[:token])
        since = params[:since].to_s
        # Without a version (none sent, NaN, anything but digits) the caller holds none: it gets
        # the current one and no update, rather than an update on every check.
        return render json: { cursor: cursor, updated: false } unless VERSION_FORMAT.match?(since)

        since = since.to_i
        render json: { cursor: [cursor, since].max, updated: cursor > since }
      end
    end
  end
end
