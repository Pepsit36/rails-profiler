# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class GetProfileDetail
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

          text = format_profile_detail(profile)

          [
            {
              type: "text",
              text: text
            }
          ]
        end

        private

        def self.format_profile_detail(profile)
          lines = []
          lines << "# Profile Details: #{profile.token}\n"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Status:** #{profile.status}"
          lines << "**Duration:** #{profile.duration.round(2)} ms"
          lines << "**Memory:** #{(profile.memory / 1024.0 / 1024.0).round(2)} MB" if profile.memory
          lines << "**Time:** #{profile.started_at}\n"

          # Request section
          req_data = profile.collector_data("request")
          if req_data
            params = req_data["params"]
            headers = req_data["headers"]

            if params && !params.empty?
              lines << "## Request Params"
              params.each { |k, v| lines << "- **#{k}**: #{v}" }
              lines << ""
            end

            if headers && !headers.empty?
              lines << "## Request Headers"
              headers.each { |k, v| lines << "- **#{k}**: #{v}" }
              lines << ""
            end
          end

          # Database section
          db_data = profile.collector_data("database")
          if db_data && db_data["total_queries"]
            lines << "## Database"
            lines << "- Total Queries: #{db_data['total_queries']}"
            lines << "- Total Duration: #{db_data['total_duration'].round(2)} ms"
            lines << "- Slow Queries: #{db_data['slow_queries']}"
            lines << "- Cached Queries: #{db_data['cached_queries']}\n"

            if db_data["queries"] && !db_data["queries"].empty?
              lines << "### Query Details"
              db_data["queries"].each_with_index do |query, index|
                lines << "\n**Query #{index + 1}** (#{query['duration'].round(2)}ms):"
                lines << "```sql"
                lines << query['sql']
                lines << "```"
                if query['backtrace'] && !query['backtrace'].empty?
                  lines << "_Backtrace:_"
                  query['backtrace'].first(3).each { |frame| lines << "  #{frame}" }
                end
              end
            end
            lines << ""
          end

          # Performance section
          perf_data = profile.collector_data("performance")
          if perf_data && perf_data["total_events"]
            lines << "## Performance Timeline"
            lines << "- Total Events: #{perf_data['total_events']}"
            lines << "- Total Duration: #{perf_data['total_duration'].round(2)} ms\n"

            if perf_data["events"] && !perf_data["events"].empty?
              lines << "### Events"
              perf_data["events"].each do |event|
                lines << "- **#{event['name']}**: #{event['duration'].round(2)} ms"
              end
            end
            lines << ""
          end

          # Views section
          view_data = profile.collector_data("view")
          if view_data && (view_data["total_views"] || view_data["total_partials"])
            lines << "## View Rendering"
            lines << "- Templates: #{view_data['total_views']}"
            lines << "- Partials: #{view_data['total_partials']}"
            lines << "- Total Duration: #{view_data['total_duration'].round(2)} ms\n"

            if view_data["views"] && !view_data["views"].empty?
              lines << "### Templates"
              view_data["views"].each do |view|
                lines << "- `#{view['identifier']}` — #{view['duration'].round(2)} ms"
              end
              lines << ""
            end

            if view_data["partials"] && !view_data["partials"].empty?
              lines << "### Partials"
              view_data["partials"].each do |partial|
                lines << "- `#{partial['identifier']}` — #{partial['duration'].round(2)} ms"
              end
              lines << ""
            end
          end

          # Cache section
          cache_data = profile.collector_data("cache")
          if cache_data && cache_data["total_reads"]
            lines << "## Cache"
            lines << "- Reads: #{cache_data['total_reads']}"
            lines << "- Writes: #{cache_data['total_writes']}"
            lines << "- Deletes: #{cache_data['total_deletes']}"
            lines << "- Hit Rate: #{cache_data['hit_rate']}%\n"

            if cache_data["reads"] && !cache_data["reads"].empty?
              lines << "### Cache Reads"
              cache_data["reads"].each do |op|
                hit_label = op['hit'] ? "HIT" : "MISS"
                lines << "- [#{hit_label}] `#{op['key']}` — #{op['duration'].round(2)} ms"
              end
              lines << ""
            end

            if cache_data["writes"] && !cache_data["writes"].empty?
              lines << "### Cache Writes"
              cache_data["writes"].each do |op|
                lines << "- `#{op['key']}` — #{op['duration'].round(2)} ms"
              end
              lines << ""
            end

            if cache_data["deletes"] && !cache_data["deletes"].empty?
              lines << "### Cache Deletes"
              cache_data["deletes"].each do |op|
                lines << "- `#{op['key']}` — #{op['duration'].round(2)} ms"
              end
              lines << ""
            end
          end

          # Ajax section
          ajax_data = profile.collector_data("ajax")
          if ajax_data && ajax_data["total_requests"].to_i > 0
            lines << "## AJAX Requests"
            lines << "- Total: #{ajax_data['total_requests']}"
            lines << "- Total Duration: #{ajax_data['total_duration'].round(2)} ms\n"

            if ajax_data["requests"] && !ajax_data["requests"].empty?
              lines << "### Request List"
              ajax_data["requests"].each do |req|
                lines << "- **#{req['method']} #{req['path']}** — #{req['status']} — #{req['duration'].round(2)} ms (token: #{req['token']})"
              end
              lines << ""
            end
          end

          # Dumps section
          dump_data = profile.collector_data("dump")
          if dump_data && dump_data["count"].to_i > 0
            lines << "## Variable Dumps"
            lines << "- Count: #{dump_data['count']}\n"

            dump_data["dumps"]&.each_with_index do |dump, index|
              label = dump['label'] || "Dump #{index + 1}"
              location = [dump['file'], dump['line']].compact.join(':')
              lines << "### #{label}"
              lines << "_Source: #{location}_" unless location.empty?
              lines << "```"
              lines << (dump['formatted'] || dump['value'].inspect)
              lines << "```"
            end
            lines << ""
          end

          lines.join("\n")
        end
      end
    end
  end
end
