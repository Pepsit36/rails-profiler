# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class ClearProfiles
        def self.call(params)
          type = params["type"]

          if type && !%w[http job test console].include?(type)
            return [{ type: "text", text: "Error: type must be 'http', 'job', 'test', or 'console'" }]
          end

          Profiler.storage.clear(type: type)

          label = type ? "#{type} profiles" : "all profiles"
          [{ type: "text", text: "Cleared #{label}." }]
        end
      end
    end
  end
end
