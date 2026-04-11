# frozen_string_literal: true

module Profiler
  module Api
    class EnvVarsController < ApplicationController
      skip_before_action :verify_authenticity_token

      def show
        variables = ENV.to_h.sort.to_h
        render json: { variables: variables, total: variables.size }
      end

      def update
        key = params[:key].to_s.strip

        if key.blank?
          render json: { error: "Key cannot be blank" }, status: :unprocessable_entity
          return
        end

        value = params[:value]

        if value.nil? || value.to_s.empty?
          ENV.delete(key)
          render json: { key: key, value: nil, deleted: true }
        else
          ENV[key] = value.to_s
          render json: { key: key, value: ENV[key] }
        end
      end
    end
  end
end
