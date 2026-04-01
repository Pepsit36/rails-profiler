# frozen_string_literal: true

module Profiler
  module MCP
    module Resources
      class RecentRequests
        def self.call
          profiles = Profiler.storage.list(limit: 50)

          data = profiles.map do |profile|
            {
              token: profile.token,
              path: profile.path,
              method: profile.method,
              status: profile.status,
              duration: profile.duration&.round(2),
              memory: profile.memory ? (profile.memory / 1024.0 / 1024.0).round(2) : nil,
              timestamp: profile.started_at&.iso8601,
              query_count: profile.collector_data("database")&.dig("total_queries") || 0,
              matched_route: profile.collector_data("routes")&.dig("matched", "pattern"),
              controller_action: profile.collector_data("request")&.dig("controller_action")
            }
          end

          {
            uri: "profiler://recent",
            mimeType: "application/json",
            text: JSON.pretty_generate({
              total: data.size,
              profiles: data
            })
          }
        end
      end
    end
  end
end
