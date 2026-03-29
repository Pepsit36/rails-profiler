# frozen_string_literal: true

require "shellwords"
require "cgi"

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

          # Job section
          job_data = profile.collector_data("job")
          if job_data && job_data["job_class"]
            lines << "## Job"
            lines << "- Class: #{job_data['job_class']}"
            lines << "- Job ID: #{job_data['job_id']}"
            lines << "- Queue: #{job_data['queue']}"
            lines << "- Executions: #{job_data['executions']}"
            lines << "- Status: #{job_data['status']}"
            lines << "- Error: #{job_data['error']}" if job_data['error']
            if job_data['arguments'] && !job_data['arguments'].empty?
              lines << "- Arguments: #{job_data['arguments'].map(&:to_s).join(', ')}"
            end
            lines << ""
          end

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

            req_body = req_data["request_body"]
            if req_body && !req_body.empty?
              enc = req_data["request_body_encoding"]
              lines << "## Request Body"
              if enc == "base64"
                lines << "_[binary, base64-encoded]_"
              else
                lines << "```"
                lines << req_body
                lines << "```"
              end
              lines << ""
            end
          end

          # Response Headers section
          if profile.response_headers&.any?
            lines << "## Response Headers"
            profile.response_headers.each { |k, v| lines << "- **#{k}**: #{v}" }
            lines << ""
          end

          # Response Body section
          resp_body = profile.response_body
          if resp_body && !resp_body.empty?
            enc = profile.response_body_encoding
            lines << "## Response Body"
            if enc == "base64"
              lines << "_[binary, base64-encoded]_"
            else
              lines << "```"
              lines << resp_body
              lines << "```"
            end
            lines << ""
          end

          # Curl command
          req_data_for_curl = profile.collector_data("request")
          lines << "## Curl Command"
          lines << "```bash"
          lines << generate_curl(profile, req_data_for_curl)
          lines << "```"
          lines << ""

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

          # HTTP section
          http_data = profile.collector_data("http")
          if http_data && http_data["total_requests"].to_i > 0
            threshold = Profiler.configuration.slow_http_threshold
            lines << "## Outbound HTTP"
            lines << "- Total: #{http_data['total_requests']}"
            lines << "- Total Duration: #{http_data['total_duration'].round(2)} ms"
            lines << "- Slow (>#{threshold}ms): #{http_data['slow_requests']}"
            lines << "- Errors: #{http_data['error_requests']}\n"

            if http_data["requests"] && !http_data["requests"].empty?
              lines << "### Request List"
              http_data["requests"].each do |req|
                flag = req["duration"] >= threshold ? " [SLOW]" : ""
                err = req["status"] >= 400 || req["status"] == 0 ? " [ERROR]" : ""
                lines << "- **#{req['method']} #{req['url']}** — #{req['status'] == 0 ? 'error' : req['status']} — #{req['duration'].round(2)} ms#{flag}#{err}"
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

        def self.generate_curl(profile, req_data)
          headers  = req_data&.dig("headers")  || {}
          params   = req_data&.dig("params")   || {}
          req_body = req_data&.dig("request_body")

          parts = ["curl -X #{profile.method}"]

          headers.reject { |k, _| k == "User-Agent" }.each do |k, v|
            parts << "  -H #{Shellwords.shellescape("#{k}: #{v}")}"
          end

          if %w[POST PUT PATCH].include?(profile.method)
            if req_body && !req_body.empty?
              parts << "  -d #{Shellwords.shellescape(req_body)}"
            elsif !params.empty?
              ct = headers["Content-Type"].to_s
              if ct.include?("application/json")
                parts << "  -d #{Shellwords.shellescape(params.to_json)}"
              else
                params.each { |k, v| parts << "  --data-urlencode #{Shellwords.shellescape("#{k}=#{v}")}" }
              end
            end
          end

          url = "http://localhost:3000#{profile.path}"
          if profile.method == "GET" && !params.empty?
            qs = params.map { |k, v| "#{CGI.escape(k.to_s)}=#{CGI.escape(v.to_s)}" }.join("&")
            url += "?#{qs}"
          end

          parts << "  #{Shellwords.shellescape(url)}"
          parts.join(" \\\n")
        end
      end
    end
  end
end
