# frozen_string_literal: true

require "mcp"
require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class DeleteEnvVar
        def self.call(params)
          key = params["key"].to_s.strip

          return [{ type: "text", text: "Error: key cannot be blank." }] if key.empty?
          if Profiler::EnvOverrideStore.reserved_key?(key)
            return ::MCP::Tool::Response.new(
              [{ type: "text", text: "Error: #{Profiler::EnvOverrideStore::RESERVED_KEY_ERROR}; #{key} was left unchanged." }],
              error: true
            )
          end

          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            proxy.patch_json("/_profiler/api/env_vars", { key: key, value: "" })
            return [{ type: "text", text: "Deleted #{key} on slave '#{params["slave"]}'. Override persisted across restarts until reset." }]
          end

          Profiler.env_override_store.delete(key)
          ENV.delete(key)

          [{ type: "text", text: "Deleted #{key}. Override persisted — will remain deleted across restarts until reset." }]
        end
      end
    end
  end
end
