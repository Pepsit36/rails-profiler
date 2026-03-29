# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class ClearProfiles
        def self.call(params)
          type = params["type"]

          if type && !%w[http job].include?(type)
            return [{ type: "text", text: "Error: type must be 'http' or 'job'" }]
          end

          Profiler.storage.clear(type: type)

          label = type ? "#{type} profiles" : "all profiles (requests and jobs)"
          [{ type: "text", text: "Cleared #{label}." }]
        end
      end
    end
  end
end
