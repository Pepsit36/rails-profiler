# frozen_string_literal: true

module Profiler
  module MCP
    module Resources
      class RecentConsole
        def self.call
          profiles = Profiler.storage.list(limit: 50, type: "console")
          consoles = profiles.select { |p| p.profile_type == "console" }

          data = consoles.map do |profile|
            console_data = profile.collector_data("console") || {}
            {
              token: profile.token,
              expression: console_data["expression"],
              return_value: console_data["return_value"],
              status: profile.status == 200 ? "completed" : "failed",
              duration: profile.duration&.round(2),
              query_count: profile.collector_data("database")&.dig("total_queries") || 0,
              timestamp: profile.started_at&.iso8601
            }
          end

          {
            uri: "profiler://recent-console",
            mimeType: "application/json",
            text: JSON.pretty_generate({
              total: data.size,
              console_executions: data
            })
          }
        end
      end
    end
  end
end
