# frozen_string_literal: true

require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class GetTestProfileDetail
        def self.call(params)
          token = params["token"]
          unless token
            return [{ type: "text", text: "Error: token parameter is required" }]
          end

          storage = MCP::SlaveSupport.resolve_storage(params)
          profile = if token == "latest"
            profiles = storage.list(limit: 200)
            profiles.find { |p| p.profile_type == "test" }
          else
            storage.load(token)
          end

          unless profile && profile.profile_type == "test"
            return [{ type: "text", text: "Test profile not found: #{token}" }]
          end

          [{ type: "text", text: format_test_detail(profile) }]
        end

        private

        def self.format_test_detail(profile)
          test_data = profile.collector_data("test") || {}
          db_data   = profile.collector_data("database") || {}
          cache_data = profile.collector_data("cache") || {}
          exc_data  = profile.collector_data("exception") || {}

          queries  = db_data["queries"] || []
          n1_count = count_n1_patterns(queries)

          lines = []
          lines << "# Test Profile Detail\n"

          # Overview
          lines << "## Overview"
          lines << "| Field | Value |"
          lines << "|-------|-------|"
          lines << "| Token | `#{profile.token}` |"
          lines << "| Test name | #{test_data["test_name"] || profile.path} |"
          lines << "| Status | #{test_data["status"] || "unknown"} |"
          lines << "| Framework | #{test_data["framework"]} |"
          lines << "| File | #{test_data["test_file"]}:#{test_data["test_line"]} |"
          lines << "| Duration | #{profile.duration&.round(2)}ms |"
          lines << "| Assertions | #{test_data["assertions"] || "-"} |"
          lines << "| Allocated objects | #{profile.allocated_objects || "-"} |"
          lines << "| Time | #{profile.started_at&.strftime("%H:%M:%S")} |"

          # Exception / skip
          if test_data["exception_message"]
            lines << "\n## Exception"
            lines << "```\n#{test_data["exception_message"]}\n```"
          elsif test_data["skip_reason"]
            lines << "\n## Skip reason"
            lines << test_data["skip_reason"].to_s
          end

          # Unhandled exception (ExceptionCollector)
          if exc_data["exception_class"]
            lines << "\n## Unhandled Exception"
            lines << "**#{exc_data["exception_class"]}**: #{exc_data["exception_message"]}"
            if (backtrace = exc_data["backtrace"]).is_a?(Array) && backtrace.any?
              lines << "\n```"
              backtrace.first(5).each { |l| lines << l }
              lines << "```"
            end
          end

          # Database
          lines << "\n## Database (#{db_data["total_queries"].to_i} queries · #{db_data["total_duration"].to_f.round(2)}ms · #{n1_count} N+1 patterns)"
          if queries.any?
            slow_threshold = Profiler.configuration.slow_query_threshold
            slow = queries.select { |q| q["duration"].to_f >= slow_threshold }
            show = slow.any? ? slow.first(10) : queries.first(10)
            caption = slow.any? ? "Slowest queries:" : "First queries:"
            lines << caption
            lines << "| # | Duration | SQL |"
            lines << "|---|----------|-----|"
            show.each_with_index do |q, i|
              sql = q["sql"].to_s.gsub("|", "\\|").then { |s| s.length > 100 ? s[0, 97] + "..." : s }
              lines << "| #{i + 1} | #{q["duration"].to_f.round(2)}ms | `#{sql}` |"
            end

            if n1_count > 0
              lines << "\n### N+1 Patterns Detected"
              queries.group_by { |q| normalize_sql(q["sql"].to_s) }
                     .select { |_, qs| qs.size >= 3 }
                     .each do |pattern, qs|
                lines << "- `#{pattern[0, 120]}` (×#{qs.size})"
              end
            end
          else
            lines << "_No SQL queries recorded._"
          end

          # Cache
          total_cache = cache_data["total_reads"].to_i + cache_data["total_writes"].to_i + cache_data["total_deletes"].to_i
          if total_cache > 0
            lines << "\n## Cache (#{total_cache} operations)"
            lines << "- Reads: #{cache_data["total_reads"].to_i}"
            lines << "- Writes: #{cache_data["total_writes"].to_i}"
            lines << "- Deletes: #{cache_data["total_deletes"].to_i}"
            lines << "- Misses: #{cache_data["total_misses"].to_i}"
          end

          lines.join("\n")
        end

        def self.count_n1_patterns(queries)
          return 0 if queries.size < 3
          queries.group_by { |q| normalize_sql(q["sql"].to_s) }.count { |_, qs| qs.size >= 3 }
        end

        def self.normalize_sql(sql)
          sql.gsub(/\$\d+/, "?").gsub(/\b\d+\b/, "?").gsub(/'[^']*'/, "?").gsub(/"[^"]*"/, "?").strip
        end
      end
    end
  end
end
