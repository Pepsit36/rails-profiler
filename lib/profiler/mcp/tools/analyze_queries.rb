# frozen_string_literal: true

require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class AnalyzeQueries
        def self.call(params)
          token = params["token"]
          unless token
            return [
              {
                type: "text",
                text: "Error: token parameter is required"
              }
            ]
          end

          storage = MCP::SlaveSupport.resolve_storage(params)
          profile = if token == "latest"
            storage.list(limit: 1).first
          else
            storage.load(token)
          end
          unless profile
            return [
              {
                type: "text",
                text: "Profile not found: #{token}"
              }
            ]
          end

          db_data = profile.collector_data("database")
          unless db_data && db_data["queries"]
            return [
              {
                type: "text",
                text: "No database queries found in this profile"
              }
            ]
          end

          summary_only = params["summary_only"] == true || params["summary_only"] == "true"
          text = analyze_and_format(db_data["queries"], summary_only: summary_only)

          [
            {
              type: "text",
              text: text
            }
          ]
        end

        private

        def self.analyze_and_format(queries, summary_only: false)
          lines = []
          lines << "# SQL Query Analysis\n"

          slow_threshold = Profiler.configuration.slow_query_threshold
          slow_queries = queries.select { |q| q["duration"] > slow_threshold }
          query_counts = queries.group_by { |q| normalize_sql(q["sql"]) }
                               .transform_values { |qs| { count: qs.size, backtrace: qs.first["backtrace"] || [] } }
                               .select { |_, v| v[:count] >= 3 }

          unless summary_only
            # Detect slow queries
            if slow_queries.any?
              lines << "## ⚠️ Slow Queries (> #{slow_threshold}ms)"
              lines << "Found #{slow_queries.size} slow queries:\n"

              slow_queries.first(5).each_with_index do |query, index|
                lines << "### Query #{index + 1} - #{query['duration'].round(2)}ms"
                lines << "```sql"
                lines << query["sql"]
                lines << "```\n"
              end

              lines << "_... and #{slow_queries.size - 5} more slow queries_\n" if slow_queries.size > 5
            else
              lines << "## ✅ No Slow Queries"
              lines << "All queries executed in less than #{slow_threshold}ms\n"
            end

            # Detect duplicate queries (potential N+1, threshold: ≥ 3 occurrences)
            if query_counts.any?
              lines << "## ⚠️ Duplicate Queries (Potential N+1)"
              lines << "Found #{query_counts.size} query pattern(s) repeated 3+ times:\n"

              query_counts.sort_by { |_, v| -v[:count] }.first(5).each do |sql, v|
                lines << "### Executed #{v[:count]} times:"
                lines << "```sql"
                lines << sql
                lines << "```"
                if v[:backtrace].any?
                  lines << "#### Called from:"
                  v[:backtrace].first(3).each { |frame| lines << "  #{frame}" }
                end
                lines << ""
              end

              lines << "_... and #{query_counts.size - 5} more duplicate patterns_\n" if query_counts.size > 5
            else
              lines << "## ✅ No Duplicate Queries"
              lines << "No query pattern repeated 3+ times\n"
            end
          end

          # Summary statistics always included
          lines << "## Summary Statistics"
          lines << "- **Total Queries:** #{queries.size}"
          lines << "- **Total Duration:** #{queries.sum { |q| q['duration'] }.round(2)}ms"
          lines << "- **Average Duration:** #{(queries.sum { |q| q['duration'] } / queries.size).round(2)}ms"
          lines << "- **Slow Queries:** #{slow_queries.size}"
          lines << "- **N+1 Patterns (≥3×):** #{query_counts.size}"
          lines << "- **Cached Queries:** #{queries.count { |q| q['cached'] }}"

          lines.join("\n")
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
