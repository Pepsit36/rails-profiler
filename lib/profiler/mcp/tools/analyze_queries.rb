# frozen_string_literal: true

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

          profile = Profiler.storage.load(token)
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

          text = analyze_and_format(db_data["queries"])

          [
            {
              type: "text",
              text: text
            }
          ]
        end

        private

        def self.analyze_and_format(queries)
          lines = []
          lines << "# SQL Query Analysis\n"

          # Detect slow queries
          slow_threshold = Profiler.configuration.slow_query_threshold
          slow_queries = queries.select { |q| q["duration"] > slow_threshold }

          if slow_queries.any?
            lines << "## ⚠️ Slow Queries (> #{slow_threshold}ms)"
            lines << "Found #{slow_queries.size} slow queries:\n"

            slow_queries.first(5).each_with_index do |query, index|
              lines << "### Query #{index + 1} - #{query['duration'].round(2)}ms"
              lines << "```sql"
              lines << query['sql']
              lines << "```\n"
            end

            if slow_queries.size > 5
              lines << "_... and #{slow_queries.size - 5} more slow queries_\n"
            end
          else
            lines << "## ✅ No Slow Queries"
            lines << "All queries executed in less than #{slow_threshold}ms\n"
          end

          # Detect duplicate queries (potential N+1)
          query_counts = queries.group_by { |q| normalize_sql(q["sql"]) }
                               .transform_values(&:count)
                               .select { |_, count| count > 1 }

          if query_counts.any?
            lines << "## ⚠️ Duplicate Queries (Potential N+1)"
            lines << "Found #{query_counts.size} duplicate query patterns:\n"

            query_counts.sort_by { |_, count| -count }.first(5).each do |sql, count|
              lines << "### Executed #{count} times:"
              lines << "```sql"
              lines << sql
              lines << "```\n"
            end

            if query_counts.size > 5
              lines << "_... and #{query_counts.size - 5} more duplicate patterns_\n"
            end
          else
            lines << "## ✅ No Duplicate Queries"
            lines << "No potential N+1 query problems detected\n"
          end

          # Overall statistics
          lines << "## Summary Statistics"
          lines << "- **Total Queries:** #{queries.size}"
          lines << "- **Total Duration:** #{queries.sum { |q| q['duration'] }.round(2)}ms"
          lines << "- **Average Duration:** #{(queries.sum { |q| q['duration'] } / queries.size).round(2)}ms"
          lines << "- **Slow Queries:** #{slow_queries.size}"
          lines << "- **Duplicate Patterns:** #{query_counts.size}"
          lines << "- **Cached Queries:** #{queries.count { |q| q['cached'] }}"

          lines.join("\n")
        end

        def self.normalize_sql(sql)
          # Normalize SQL by removing bind values for comparison
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
