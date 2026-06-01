# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class ResetAllEnvVars
        def self.call(_params)
          overrides = Profiler.env_override_store.all_overrides
          count = overrides.size

          if count.zero?
            return [{ type: "text", text: "No active overrides to reset." }]
          end

          Profiler.env_override_store.reset_all

          [{ type: "text", text: "Reset #{count} environment variable#{"s" if count != 1} to original values." }]
        end
      end
    end
  end
end
