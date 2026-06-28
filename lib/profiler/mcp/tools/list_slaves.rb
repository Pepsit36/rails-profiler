# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class ListSlaves
        def self.call(_params)
          slaves = Profiler.slave_registry.all

          if slaves.empty?
            return [{ type: "text", text: "No slave profilers connected." }]
          end

          lines = ["# Connected Slave Profilers\n"]
          lines << "| Name | URL | Status | Registered At | Last Heartbeat |"
          lines << "|------|-----|--------|--------------|----------------|"

          slaves.each do |s|
            lines << "| #{s[:name]} | #{s[:url]} | #{s[:status]} | #{s[:registered_at]} | #{s[:last_heartbeat_at]} |"
          end

          [{ type: "text", text: lines.join("\n") }]
        end
      end
    end
  end
end
