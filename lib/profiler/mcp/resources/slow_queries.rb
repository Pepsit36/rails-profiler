# frozen_string_literal: true

module Profiler
  module MCP
    module Resources
      class SlowQueries
        def self.call
          profiles = Profiler.storage.list(limit: 100)
          slow_threshold = Profiler.configuration.slow_query_threshold

          slow_queries = []

          profiles.each do |profile|
            db_data = profile.collector_data("database")
            next unless db_data && db_data["queries"]

            db_data["queries"].each do |query|
              if query["duration"] > slow_threshold
                slow_queries << {
                  profile_token: profile.token,
                  profile_path: profile.path,
                  sql: query["sql"],
                  duration: query["duration"].round(2),
                  timestamp: profile.started_at&.iso8601
                }
              end
            end
          end

          # Sort by duration descending
          slow_queries.sort_by! { |q| -q[:duration] }
          slow_queries = slow_queries.first(50)

          {
            uri: "profiler://slow-queries",
            mimeType: "application/json",
            text: JSON.pretty_generate({
              threshold: slow_threshold,
              total: slow_queries.size,
              queries: slow_queries
            })
          }
        end
      end
    end
  end
end
