# frozen_string_literal: true

require "profiler/explain_runner"

module Profiler
  module Api
    class ExplainController < ApplicationController
      skip_before_action :verify_authenticity_token

      def create
        unless Profiler.configuration.enabled
          return render json: { error: "EXPLAIN is only available when the profiler is enabled" }, status: :forbidden
        end

        token       = params[:token].to_s
        query_index = params[:query_index].to_i

        if token.blank?
          return render json: { error: "token is required" }, status: :unprocessable_entity
        end

        result = Profiler::ExplainRunner.run(token, query_index)
        render json: result
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue => e
        render json: { error: e.message }, status: :internal_server_error
      end
    end
  end
end
