# frozen_string_literal: true

module Profiler
  module Api
    class EnvVarsController < ApplicationController
      def show
        variables = ENV.to_h.sort.to_h
        overrides = Profiler.env_override_store.all_overrides
        render json: { variables: variables, total: variables.size, overrides: overrides }
      end

      def update
        key = params[:key].to_s.strip

        if key.blank?
          render json: { error: "Key cannot be blank" }, status: :unprocessable_entity
          return
        end

        value = params[:value]

        if value.nil? || value.to_s.empty?
          Profiler.env_override_store.delete(key)
          ENV.delete(key)
          render json: { key: key, value: nil, deleted: true, override: Profiler.env_override_store.all_overrides[key] }
        else
          current_original = Profiler.env_override_store.all_overrides.dig(key, "original")
          if current_original == value.to_s
            Profiler.env_override_store.reset(key)
          else
            Profiler.env_override_store.set(key, value.to_s)
          end
          ENV[key] = value.to_s
          render json: { key: key, value: ENV[key], override: Profiler.env_override_store.all_overrides[key] }
        end
      end

      def reset_override
        key = params[:key].to_s.strip

        if key.blank?
          render json: { error: "Key cannot be blank" }, status: :unprocessable_entity
          return
        end

        Profiler.env_override_store.reset(key)
        render json: { key: key, value: ENV[key], reset: true }
      end

      def reset_all
        Profiler.env_override_store.reset_all
        render json: { reset: true }
      end
    end
  end
end
