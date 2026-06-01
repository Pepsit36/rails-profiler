# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class SetEnvVar
        def self.call(params)
          key = params["key"].to_s.strip
          value = params["value"].to_s

          return [{ type: "text", text: "Error: key cannot be blank." }] if key.empty?

          Profiler.env_override_store.set(key, value)
          ENV[key] = value

          [{ type: "text", text: "Set #{key}=#{value}" }]
        end
      end
    end
  end
end
