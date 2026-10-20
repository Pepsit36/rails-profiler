# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class CompareProfiles
        def self.call(params)
          token_a = params["token_a"]
          token_b = params["token_b"]

          errors = []
          errors << "Missing parameter: token_a" if token_a.nil? || token_a.empty?
          errors << "Missing parameter: token_b" if token_b.nil? || token_b.empty?

          if errors.any?
            return [{ type: "text", text: "Error: #{errors.join(', ')}" }]
          end

          node_a = params["node_a"].to_s
          node_b = params["node_b"].to_s

          if token_a == token_b && node_a == node_b
            return [{ type: "text", text: "Error: Cannot compare a profile with itself" }]
          end

          begin
            diff = ProfileComparison.call(token_a, token_b, node_a: node_a, node_b: node_b)
          rescue Profiler::Error => e
            return [{ type: "text", text: e.message.start_with?("Profile not found") ? e.message : "Error: #{e.message}" }]
          end

          [{ type: "text", text: format_diff(diff) }]
        end

        def self.format_diff(diff)
          pa = diff[:profile_a]
          pb = diff[:profile_b]
          m = diff[:metrics]

          lines = []
          lines << "# Profile Comparison\n"
          lines << "**A:** `#{pa[:token]}` on #{pa[:node]}: #{pa[:method]} #{pa[:path]} (#{pa[:started_at]})"
          lines << "**B:** `#{pb[:token]}` on #{pb[:node]}: #{pb[:method]} #{pb[:path]} (#{pb[:started_at]})\n"

          unless diff[:same_endpoint]
            lines << "⚠️ **Warning:** These profiles are from different endpoints - comparison may not be meaningful.\n"
          end

          lines << "## Scorecard\n"
          lines << "| Metric | A | B | Delta | Status |"
          lines << "|--------|---|---|-------|--------|"

          append_metric(lines, "Duration (ms)", m[:duration])
          append_metric(lines, "Allocated objects", m[:allocated_objects])
          append_metric(lines, "DB Queries", m[:db_queries])
          append_metric(lines, "DB Duration (ms)", m[:db_duration])
          append_metric(lines, "Cache Hit Rate (%)", m[:cache_hit_rate])
          append_metric(lines, "View Duration (ms)", m[:view_duration])
          append_metric(lines, "HTTP Requests", m[:http_requests])
          append_metric(lines, "HTTP Duration (ms)", m[:http_duration])

          lines << ""
          lines += format_sql(diff[:sql])
          lines += format_database(diff[:collectors][:database])
          lines += format_cache(diff[:collectors][:cache])
          lines += format_views(diff[:collectors][:views])
          lines += format_http(diff[:collectors][:http])

          lines.join("\n")
        end

        def self.append_metric(lines, label, metric, formatter = nil)
          return unless metric

          fmt = formatter || ->(v) { v&.round(2)&.to_s || "-" }
          val_a = fmt.call(metric[:value_a])
          val_b = fmt.call(metric[:value_b])
          delta = metric[:delta]
          delta_pct = metric[:delta_pct]
          sign = delta >= 0 ? "+" : ""
          delta_str = "#{sign}#{delta.round(2)}"
          delta_str += " (#{sign}#{delta_pct}%)" if delta_pct

          icon = case metric[:status]
                 when :improved then "✅"
                 when :regression then "❌"
                 else "➖"
                 end

          lines << "| #{label} | #{val_a} | #{val_b} | #{delta_str} | #{icon} |"
        end

        def self.markdown_table(title, guard_key, data, rows)
          return [] unless data[guard_key]

          lines = ["## #{title}\n", "| Metric | A | B |", "|--------|---|---|"]
          rows.each { |label, a, b| lines << "| #{label} | #{a || '-'} | #{b || '-'} |" }
          lines << ""
          lines
        end

        def self.format_database(db)
          markdown_table("Database", :total_queries_a, db, [
            ["Total Queries",       db[:total_queries_a],                db[:total_queries_b]],
            ["Total Duration (ms)", db[:total_duration_a]&.round(2),     db[:total_duration_b]&.round(2)],
            ["Slow Queries",        db[:slow_queries_a],                 db[:slow_queries_b]],
            ["Cached Queries",      db[:cached_queries_a],               db[:cached_queries_b]]
          ])
        end

        def self.format_sql(sql)
          lines = []
          { new: "New queries (only in B)", gone: "Gone queries (only in A)", slower: "Slower queries" }.each do |key, title|
            lines << "## #{title}\n"
            if sql[key].empty?
              lines << "None.\n"
              next
            end

            lines << "| Query | Count A | Count B | Time A (ms) | Time B (ms) |"
            lines << "|-------|---------|---------|-------------|-------------|"
            sql[key].each do |q|
              lines << "| `#{q[:fingerprint].to_s.gsub("|", "\\|").slice(0, 120)}` | #{q[:count_a]} | #{q[:count_b]} | " \
                       "#{q[:total_duration_a]} | #{q[:total_duration_b]} |"
            end
            lines << ""
          end
          lines
        end

        def self.format_cache(cache)
          markdown_table("Cache", :hit_rate_a, cache, [
            ["Total Reads",  cache[:total_reads_a],  cache[:total_reads_b]],
            ["Total Writes", cache[:total_writes_a], cache[:total_writes_b]],
            ["Hit Rate (%)", cache[:hit_rate_a],     cache[:hit_rate_b]]
          ])
        end

        def self.format_views(views)
          markdown_table("Views", :total_duration_a, views, [
            ["Templates",           views[:total_views_a],                views[:total_views_b]],
            ["Partials",            views[:total_partials_a],             views[:total_partials_b]],
            ["Total Duration (ms)", views[:total_duration_a]&.round(2),  views[:total_duration_b]&.round(2)]
          ])
        end

        def self.format_http(http)
          markdown_table("Outbound HTTP", :total_requests_a, http, [
            ["Total Requests",      http[:total_requests_a],              http[:total_requests_b]],
            ["Total Duration (ms)", http[:total_duration_a]&.round(2),   http[:total_duration_b]&.round(2)],
            ["Slow Requests",       http[:slow_requests_a],               http[:slow_requests_b]],
            ["Error Requests",      http[:error_requests_a],              http[:error_requests_b]]
          ])
        end
      end
    end
  end
end
