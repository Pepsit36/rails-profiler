# frozen_string_literal: true

require_relative "../slave_support"

require "uri"

module Profiler
  module MCP
    module Tools
      class ClearProfiles
        def self.call(params)
          type = params["type"]

          if type && !%w[http job test console].include?(type)
            return [{ type: "text", text: "Error: type must be 'http', 'job', 'test', or 'console'" }]
          end

          if (proxy = MCP::SlaveSupport.with_slave_proxy(params))
            path = "/_profiler/api/profiles/clear"
            path += "?type=#{URI.encode_www_form_component(type)}" if type
            proxy.delete_json(path)
          else
            Profiler.storage.clear(type: type)
          end

          label = type ? "#{type} profiles" : "all profiles"
          [{ type: "text", text: "Cleared #{label}." }]
        end
      end
    end
  end
end
