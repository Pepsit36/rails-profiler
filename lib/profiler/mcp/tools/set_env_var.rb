# frozen_string_literal: true

require "mcp"
require_relative "../slave_support"
require_relative "../../redaction"

module Profiler
  module MCP
    module Tools
      class SetEnvVar
        def self.call(params)
          key = params["key"].to_s.strip
          value = params["value"].to_s

          return [{ type: "text", text: "Error: key cannot be blank." }] if key.empty?
          if Profiler::EnvOverrideStore.reserved_key?(key)
            return ::MCP::Tool::Response.new(
              [{ type: "text", text: "Error: #{Profiler::EnvOverrideStore::RESERVED_KEY_ERROR}; #{key} was left unchanged." }],
              error: true
            )
          end
          if Profiler::Redaction.mask?(value)
            return [{ type: "text", text: "Error: #{Profiler::Redaction::MASK} is the mask the profiler shows " \
                                          "in place of a hidden value, not a value; #{key} was left unchanged." }]
          end

          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            proxy.patch_json("/_profiler/api/env_vars", { key: key, value: value })
            return [{ type: "text", text: "Set #{key}=#{value} on slave '#{params["slave"]}'" }]
          end

          Profiler.env_override_store.set(key, value)
          ENV[key] = value

          [{ type: "text", text: "Set #{key}=#{value}" }]
        rescue Profiler::EnvOverrideStore::Error => e
          ::MCP::Tool::Response.new([{ type: "text", text: "Error: #{e.message}; #{key} was left unchanged." }], error: true)
        end
      end
    end
  end
end
