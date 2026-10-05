# frozen_string_literal: true

require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class QueryTestProfiles
        ALL_FIELDS = %w[time test_name status duration queries n1 token].freeze

        def self.call(params)
          limit = params["limit"]&.to_i || 20
          fetch_size = [limit * 5, 500].min
          storage = MCP::SlaveSupport.resolve_storage(params)
          profiles = storage.list(limit: fetch_size, type: "test")

          tests = profiles.select { |p| p.profile_type == "test" }

          if params["test_name"]
            term = params["test_name"].downcase
            tests = tests.select do |p|
              test_data = p.collector_data("test")
              (test_data&.dig("test_name") || p.path).to_s.downcase.include?(term)
            end
          end

          if params["status"]
            tests = tests.select do |p|
              test_data = p.collector_data("test")
              test_data && test_data["status"] == params["status"]
            end
          end

          if params["min_duration"]
            min_ms = params["min_duration"].to_f
            tests = tests.select { |p| p.duration >= min_ms }
          end

          if params["cursor"]
            cutoff = begin
              Time.parse(params["cursor"])
            rescue ArgumentError, TypeError
              nil # a cursor that is not a time is ignored, as before
            end
            tests = tests.select { |p| p.started_at < cutoff } if cutoff
          end

          tests = tests.first(limit)
          fields = params["fields"]&.map(&:to_s)

          [{ type: "text", text: format_tests_table(tests, fields, limit) }]
        end

        private

        def self.format_tests_table(tests, fields, limit)
          return "No test profiles found matching the criteria." if tests.empty?

          fields ||= ALL_FIELDS
          fields = fields & ALL_FIELDS

          lines = []
          lines << "# Test Profiles\n"
          lines << "Found #{tests.size} tests:\n"

          header = fields.map { |f| f.split("_").map(&:capitalize).join(" ") }.join(" | ")
          separator = fields.map { "------" }.join("|")
          lines << "| #{header} |"
          lines << "|#{separator}|"

          tests.each do |profile|
            test_data = profile.collector_data("test") || {}
            db_data   = profile.collector_data("database") || {}
            queries   = db_data["queries"] || []
            n1_count  = count_n1_patterns(queries)

            row = fields.map do |f|
              case f
              when "time"      then profile.started_at&.strftime("%H:%M:%S") || "-"
              when "test_name" then (test_data["test_name"] || profile.path).to_s.then { |n| n.length > 60 ? n[0, 57] + "..." : n }
              when "status"    then test_data["status"] || "-"
              when "duration"  then profile.duration ? "#{profile.duration.round(2)}ms" : "-"
              when "queries"   then db_data["total_queries"].to_i.to_s
              when "n1"        then n1_count > 0 ? "⚠ #{n1_count}" : "✓"
              when "token"     then profile.token.to_s
              end
            end
            lines << "| #{row.join(' | ')} |"
          end

          if tests.size == limit
            lines << ""
            lines << "*Next cursor: #{tests.last.started_at.iso8601}*"
          end

          lines.join("\n")
        end

        def self.count_n1_patterns(queries)
          return 0 if queries.size < 3

          queries.group_by { |q| normalize_sql(q["sql"].to_s) }
                 .count { |_, qs| qs.size >= 3 }
        end

        def self.normalize_sql(sql)
          sql.gsub(/\$\d+/, "?")
             .gsub(/\b\d+\b/, "?")
             .gsub(/'[^']*'/, "?")
             .gsub(/"[^"]*"/, "?")
             .strip
        end
      end
    end
  end
end
