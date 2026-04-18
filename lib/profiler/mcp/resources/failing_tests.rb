# frozen_string_literal: true

module Profiler
  module MCP
    module Resources
      class FailingTests
        def self.call
          profiles = Profiler.storage.list(limit: 500)
          failing = profiles.select do |p|
            next false unless p.profile_type == "test"
            test_data = p.collector_data("test") || {}
            test_data["status"] == "failed"
          end.first(20)

          data = failing.map do |profile|
            test_data = profile.collector_data("test") || {}
            db_data   = profile.collector_data("database") || {}

            {
              token: profile.token,
              test_name: test_data["test_name"] || profile.path,
              framework: test_data["framework"],
              file: "#{test_data["test_file"]}:#{test_data["test_line"]}",
              exception: test_data["exception_message"],
              duration_ms: profile.duration&.round(2),
              query_count: db_data["total_queries"].to_i,
              timestamp: profile.started_at&.iso8601
            }
          end

          {
            uri: "profiler://failing-tests",
            mimeType: "application/json",
            text: JSON.pretty_generate({ total: data.size, failing_tests: data })
          }
        end
      end
    end
  end
end
