# frozen_string_literal: true

module Profiler
  module MCP
    module Resources
      class SlowTests
        def self.call
          profiles = Profiler.storage.list(limit: 500, type: "test")
          tests = profiles.select { |p| p.profile_type == "test" }
                          .sort_by { |p| -p.duration }
                          .first(10)

          data = tests.map do |profile|
            test_data = profile.collector_data("test") || {}
            db_data   = profile.collector_data("database") || {}
            queries   = db_data["queries"] || []
            n1 = queries.group_by { |q| normalize_sql(q["sql"].to_s) }.any? { |_, qs| qs.size >= 3 }

            {
              token: profile.token,
              test_name: test_data["test_name"] || profile.path,
              status: test_data["status"],
              framework: test_data["framework"],
              file: test_data["test_file"],
              duration_ms: profile.duration&.round(2),
              query_count: db_data["total_queries"].to_i,
              n1_detected: n1,
              timestamp: profile.started_at&.iso8601
            }
          end

          {
            uri: "profiler://slow-tests",
            mimeType: "application/json",
            text: JSON.pretty_generate({ total: data.size, slow_tests: data })
          }
        end

        def self.normalize_sql(sql)
          sql.gsub(/\$\d+/, "?").gsub(/\b\d+\b/, "?").gsub(/'[^']*'/, "?").gsub(/"[^"]*"/, "?").strip
        end
      end
    end
  end
end
