# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class DeleteEnvVar
        def self.call(params)
          key = params["key"].to_s.strip

          return [{ type: "text", text: "Error: key cannot be blank." }] if key.empty?

          Profiler.env_override_store.delete(key)
          ENV.delete(key)

          [{ type: "text", text: "Deleted #{key}. Override persisted — will remain deleted across restarts until reset." }]
        end
      end
    end
  end
end
