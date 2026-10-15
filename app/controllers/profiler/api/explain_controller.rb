# frozen_string_literal: true

require "profiler/explain_runner"

module Profiler
  module Api
    class ExplainController < ApplicationController
      def create
        if (reason = Profiler::ExplainRunner.refusal)
          return render json: { error: reason }, status: :forbidden
        end

        token       = params[:token].to_s
        query_index = params[:query_index].to_i

        if token.blank?
          return render json: { error: "token is required" }, status: :unprocessable_entity
        end

        result = Profiler::ExplainRunner.run(token, query_index)
        render json: result
      rescue Profiler::ExplainRunner::RefusedError => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue StandardError => e
        # The database's message carries the SQL, and sometimes a path: the log only.
        Profiler.log_error("Explain: failed for query #{query_index} of profile #{token.inspect}", e)
        render json: { error: "Explain failed" }, status: :internal_server_error
      end
    end
  end
end
