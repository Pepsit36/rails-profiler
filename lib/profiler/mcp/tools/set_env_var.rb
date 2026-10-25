# frozen_string_literal: true

require "mcp"
require_relative "../slave_support"
require_relative "../../env_key_policy"
require_relative "../../redaction"

module Profiler
  module MCP
    module Tools
      class SetEnvVar
        def self.call(params)
          key = params["key"].to_s.strip
          value = params["value"].to_s

          return [{ type: "text", text: "Error: key cannot be blank." }] if key.empty?
          # Checked before the store is written, and before a slave is asked: a refused key or value
          # never reaches the file nor ENV.
          if (reason = Profiler::EnvKeyPolicy.rejection(key) || Profiler::EnvKeyPolicy.value_rejection(key, value))
            return ::MCP::Tool::Response.new(
              [{ type: "text", text: "Error: #{reason}; #{key} was left unchanged." }],
              error: true
            )
          end
          if Profiler::Redaction.mask?(value)
            return [{ type: "text", text: "Error: #{Profiler::Redaction::MASK} is the mask the profiler shows " \
                                          "in place of a hidden value, not a value; #{key} was left unchanged." }]
          end

          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            data = proxy.patch_json("/_profiler/api/env_vars", { key: key, value: value })
            return ::MCP::Tool::Response.new([{ type: "text", text: "Error: #{data["error"]}" }], error: true) if data["error"]
            return [{ type: "text", text: "Set #{key}=#{value} on slave '#{params["slave"]}'" }]
          end

          if value.empty?
            Profiler.env_override_store.delete(key)
            ENV.delete(key)
            [{ type: "text", text: "Deleted #{key}" }]
          else
            Profiler.env_override_store.set(key, value)
            ENV[key] = value
            [{ type: "text", text: "Set #{key}=#{value}" }]
          end
        rescue Profiler::EnvOverrideStore::Error => e
          ::MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}; #{key} was left unchanged." }], error: true)
        end
      end
    end
  end
end
