# frozen_string_literal: true

require "mcp"
require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class ResetAllEnvVars
        def self.call(params)
          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            proxy.delete_json("/_profiler/api/env_vars/reset_all")
            return [{ type: "text", text: "Reset all ENV overrides on slave '#{params["slave"]}'." }]
          end

          overrides = Profiler.env_override_store.all_overrides
          count = overrides.size

          if count.zero?
            return [{ type: "text", text: "No active overrides to reset." }]
          end

          Profiler.env_override_store.reset_all

          [{ type: "text", text: "Reset #{count} environment variable#{"s" if count != 1} to original values." }]
        rescue Profiler::EnvOverrideStore::Error => e
          ::MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}; nothing was changed." }], error: true)
        end
      end
    end
  end
end
