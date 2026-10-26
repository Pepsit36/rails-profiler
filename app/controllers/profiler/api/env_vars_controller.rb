# frozen_string_literal: true

module Profiler
  module Api
    class EnvVarsController < ApplicationController
      # The overrides file could not be read or written: nothing was changed, ENV included.
      rescue_from Profiler::EnvOverrideStore::Error do |error|
        key = params[:key].to_s.strip
        message = key.empty? ? "#{error.message}; nothing was changed" : "#{error.message}; #{key} was left unchanged"
        render json: { error: message }, status: :internal_server_error
      end

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

        # Checked before the store is written: a refused key never reaches the file nor ENV.
        if (reason = Profiler::EnvKeyPolicy.rejection(key))
          render json: { error: "#{reason}; #{key} was left unchanged" }, status: :unprocessable_entity
          return
        end

        value = params[:value]

        # A structured value (JSON array or object) has no ENV representation. Scalars (numbers,
        # booleans) are still coerced with to_s, as before.
        if value.is_a?(Array) || value.is_a?(Hash) || value.respond_to?(:to_unsafe_h)
          render json: { error: "Value must be a scalar, not an array or an object; #{key} was left unchanged" },
                 status: :unprocessable_entity
          return
        end

        # A value ENV cannot hold is refused before the store is written, like a refused key.
        if (reason = Profiler::EnvKeyPolicy.value_rejection(key, value))
          render json: { error: "#{reason}; #{key} was left unchanged" }, status: :unprocessable_entity
          return
        end

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
          # Where the overrides are blocked, set records this process's value, which reset would not.
          if current_original == value.to_s && Profiler.env_override_store.blocked_reason.nil?
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

        # EnvOverrideStore#reset already drops a blocked key from the overrides file instead of
        # restoring it (see EnvKeyPolicy), so this removes a stale entry left by an older version
        # the same way reset_all and the MCP reset_env_var tool do, rather than leaving it stuck
        # until a full reset_all. An invalid or reserved name is a different, pre-existing case
        # (cleaning up garbage left in the file): it is removed the same way, without an error.
        Profiler.env_override_store.reset(key)

        # code_loading? also answers true for an invalid name (by design, for the test runner):
        # excluded here, since an invalid name is cleaned up without an error, not "protected".
        if Profiler::EnvKeyPolicy.valid_name?(key) &&
           (Profiler::EnvKeyPolicy.protected?(key) || Profiler::EnvKeyPolicy.code_loading?(key))
          render json: { error: "#{key} is protected; it was removed from the overrides but not restored" },
                 status: :unprocessable_entity
          return
        end

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

      # Read back after a change that succeeded: a failure here must not answer that nothing changed.
      def redacted_override(key)
        Profiler::Redaction.env_overrides(Profiler.env_override_store.all_overrides)[key]
      rescue Profiler::EnvOverrideStore::Error
        nil
      end
    end
  end
end
