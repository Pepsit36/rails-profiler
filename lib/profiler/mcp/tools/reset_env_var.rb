# frozen_string_literal: true

require_relative "../slave_support"
require_relative "../../redaction"

require "uri"

module Profiler
  module MCP
    module Tools
      class ResetEnvVar
        def self.call(params)
          key = params["key"].to_s.strip

          return [{ type: "text", text: "Error: key cannot be blank." }] if key.empty?

          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            proxy.delete_json("/_profiler/api/env_vars/reset?key=#{URI.encode_www_form_component(key)}")
            return [{ type: "text", text: "Reset #{key} on slave '#{params["slave"]}'." }]
          end

          overrides = Profiler.env_override_store.all_overrides
          unless overrides.key?(key)
            return [{ type: "text", text: "No active override for #{key}." }]
          end

          original = overrides[key]["original"]
          Profiler.env_override_store.reset(key)

          restored = original.nil? ? "(unset)" : Profiler::Redaction.env_value(key, original)
          [{ type: "text", text: "Reset #{key} to original value: #{restored}" }]
        end
      end
    end
  end
end
