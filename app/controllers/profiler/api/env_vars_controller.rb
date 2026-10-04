# frozen_string_literal: true

module Profiler
  module Api
    class EnvVarsController < ApplicationController
      def show
        variables = Profiler::Redaction.env_snapshot
        overrides = Profiler::Redaction.env_overrides(Profiler.env_override_store.all_overrides)
        render json: { variables: variables, total: variables.size, overrides: overrides }
      end

      def update
        key = params[:key].to_s.strip

        if key.blank?
          render json: { error: "Key cannot be blank" }, status: :unprocessable_entity
          return
        end

        value = params[:value]

        if Profiler::Redaction.mask?(value)
          render json: { error: "#{Profiler::Redaction::MASK} is the mask the profiler shows in place of a " \
                                "hidden value, not a value; #{key} was left unchanged" },
                 status: :unprocessable_entity
          return
        end

        if value.nil? || value.to_s.empty?
          Profiler.env_override_store.delete(key)
          ENV.delete(key)
          render json: { key: key, value: nil, deleted: true, override: redacted_override(key) }
        else
          current_original = Profiler.env_override_store.all_overrides.dig(key, "original")
          if current_original == value.to_s
            Profiler.env_override_store.reset(key)
          else
            Profiler.env_override_store.set(key, value.to_s)
          end
          ENV[key] = value.to_s
          render json: { key: key, value: redacted_value(key), override: redacted_override(key) }
        end
      end

      def reset_override
        key = params[:key].to_s.strip

        if key.blank?
          render json: { error: "Key cannot be blank" }, status: :unprocessable_entity
          return
        end

        Profiler.env_override_store.reset(key)
        render json: { key: key, value: redacted_value(key), reset: true }
      end

      def reset_all
        Profiler.env_override_store.reset_all
        render json: { reset: true }
      end

      private

      def redacted_value(key)
        ENV[key].nil? ? nil : Profiler::Redaction.env_value(key, ENV[key])
      end

      def redacted_override(key)
        Profiler::Redaction.env_overrides(Profiler.env_override_store.all_overrides)[key]
      end
    end
  end
end
