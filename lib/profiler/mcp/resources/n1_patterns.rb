# frozen_string_literal: true

module Profiler
  module MCP
    module Resources
      class N1Patterns
        def self.call
          profiles = Profiler.storage.list(limit: 100)

          # Map normalized SQL -> list of occurrences across profiles
          pattern_map = Hash.new { |h, k| h[k] = [] }

          profiles.each do |profile|
            db_data = profile.collector_data("database")
            next unless db_data && db_data["queries"]

            query_groups = db_data["queries"].group_by { |q| normalize_sql(q["sql"]) }

            query_groups.each do |normalized_sql, queries|
              pattern_map[normalized_sql] << {
                token: profile.token,
                path: profile.path,
                count: queries.size,
                timestamp: profile.started_at&.iso8601,
                backtrace: (queries.first["backtrace"] || []).first(3)
              }
            end
          end

          # Keep only patterns that appear in more than one profile OR appear multiple times in a single profile
          n1_patterns = pattern_map.select do |_, occurrences|
            occurrences.size > 1 || occurrences.any? { |o| o[:count] > 1 }
          end

          # Sort by total occurrence count descending
          sorted = n1_patterns.map do |sql, occurrences|
            total = occurrences.sum { |o| o[:count] }
            sample_backtrace = occurrences.find { |o| o[:backtrace].any? }&.dig(:backtrace) || []
            { sql: sql, total_occurrences: total, backtrace: sample_backtrace, profiles: occurrences }
          end.sort_by { |p| -p[:total_occurrences] }.first(20)

          {
            uri: "profiler://n1-patterns",
            mimeType: "application/json",
            text: JSON.pretty_generate({
              scanned_profiles: profiles.size,
              total_patterns: sorted.size,
              patterns: sorted
            })
          }
        end

        def self.normalize_sql(sql)
          sql.gsub(/\$\d+/, '?')
             .gsub(/\b\d+\b/, '?')
             .gsub(/'[^']*'/, '?')
             .gsub(/"[^"]*"/, '?')
             .strip
        end
      end
    end
  end
end
