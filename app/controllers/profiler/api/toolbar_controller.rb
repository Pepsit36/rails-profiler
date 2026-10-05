# frozen_string_literal: true

module Profiler
  module Api
    class ToolbarController < Profiler::ApplicationController
      def show
        # Read before the profile: a save landing in between makes the toolbar fetch it again
        # rather than miss it.
        events_cursor = Profiler::SSE.current.version(params[:token])
        profile = Profiler.storage.load(params[:token])

        unless profile
          render json: { error: "Profile not found" }, status: :not_found
          return
        end

        # Recalculate AJAX collector data (since AJAX requests happen after page load)
        recalculate_ajax_data(profile)
        # The route table and ENV are the process's, not stored in the profile
        Profiler::ProcessSnapshot.hydrate(profile)

        # The bodies as stored (gzip+base64 past compress_body_threshold): the toolbar shows none.
        render json: {
          profile: profile.to_h.merge(child_jobs: build_child_jobs(profile)),
          events_cursor: events_cursor
        }
      end
    end
  end
end
