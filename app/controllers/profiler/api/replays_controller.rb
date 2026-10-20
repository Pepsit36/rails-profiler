# frozen_string_literal: true

require "profiler/replay"

module Profiler
  module Api
    # POST /_profiler/api/profiles/:id/replay. The dashboard asks the user to confirm before it
    # calls this; the confirmation is the client's, not checked here (the MCP tool has none).
    class ReplaysController < ApplicationController
      def create
        options = replay_params
        result = Profiler::Replay.call(params[:id].to_s, options)
        render json: result.to_h
      rescue Profiler::Replay::Disabled => e
        render json: { error: e.message }, status: :forbidden
      rescue Profiler::Replay::NotFound => e
        render json: { error: e.message }, status: :not_found
      rescue Profiler::Replay::Error => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      # Every key of the body goes to Replay, which refuses the ones that name a host or a URL.
      def replay_params
        body = request.request_parameters.to_h
        body.except("id", "controller", "action", "replay", "format")
      end
    end
  end
end
