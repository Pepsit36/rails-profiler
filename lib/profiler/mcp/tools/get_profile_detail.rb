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

          profile = if token == "latest"
            Profiler.storage.list(limit: 1).first
          else
            Profiler.storage.load(token)
          end
          unless profile
            return [
              {
                type: "text",
                text: "Profile not found: #{token}"
              }
            ]
          end

          text = format_profile_detail(profile, params)

          [
            {
              type: "text",
              text: text
            }
          ]
        end

        private

        def self.format_profile_detail(profile, params = {})
          requested = params["sections"]&.map(&:to_s)
          want = ->(name) { requested.nil? || requested.include?(name) }

          lines = []
          lines += section_overview(profile)              if want.("overview")
          lines += section_exception(profile)             if want.("exception")
          lines += section_job(profile)                   if want.("job")
          lines += section_request(profile, params)       if want.("request")
          lines += section_response(profile, params)      if want.("response")
          lines += section_curl(profile)                  if want.("curl")
          lines += section_database(profile)              if want.("database")
          lines += section_performance(profile)           if want.("performance")
          lines += section_views(profile)                 if want.("views")
          lines += section_cache(profile)                 if want.("cache")
          lines += section_ajax(profile)                  if want.("ajax")
          lines += section_http(profile)                  if want.("http")
          lines += section_routes(profile)                if want.("routes")
          lines += section_dumps(profile)                 if want.("dumps")
          lines += section_related_jobs(profile)          if want.("related_jobs")
          lines.join("\n")
        end

        def self.section_overview(profile)
          lines = []
          lines << "# Profile Details: #{profile.token}\n"
          lines << "**Type:** #{profile.profile_type == 'job' ? 'Job' : 'HTTP Request'}"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Status:** #{profile.status}"
          lines << "**Duration:** #{profile.duration.round(2)} ms"
          lines << "**Memory:** #{(profile.memory / 1024.0 / 1024.0).round(2)} MB" if profile.memory
          lines << "**Time:** #{profile.started_at}"
          lines << "**Parent Token:** #{profile.parent_token}" if profile.parent_token
          lines << ""
          lines
        end

        def self.section_exception(profile)
          lines = []
          exception_data = profile.collector_data("exception")
          return lines unless exception_data && exception_data["exception_class"]

          lines << "## Exception"
          lines << "**Class:** #{exception_data['exception_class']}"
          lines << "**Message:** #{exception_data['message']}\n"

          backtrace = exception_data["backtrace"]
          if backtrace && !backtrace.empty?
            lines << "### Backtrace"
            backtrace.first(20).each do |frame|
              marker = frame["app_frame"] ? "★ " : "  "
              lines << "#{marker}#{frame['location']}"
            end
            lines << ""
          end
          lines
        end

        def self.section_job(profile)
          lines = []
          job_data = profile.collector_data("job")
          return lines unless job_data && job_data["job_class"]

          lines << "## Job"
          lines << "- Class: #{job_data['job_class']}"
          lines << "- Job ID: #{job_data['job_id']}"
          lines << "- Queue: #{job_data['queue']}"
          lines << "- Executions: #{job_data['executions']}"
          lines << "- Status: #{job_data['status']}"
          lines << "- Error: #{job_data['error']}" if job_data["error"]
          if job_data["arguments"] && !job_data["arguments"].empty?
            lines << "- Arguments: #{job_data['arguments'].map(&:to_s).join(', ')}"
          end
          lines << ""
          lines
        end

        def self.section_request(profile, params)
          lines = []
          req_data = profile.collector_data("request")
          return lines unless req_data

          request_params = req_data["params"]
          headers = req_data["headers"]

          if request_params && !request_params.empty?
            lines << "## Request Params"
            request_params.each { |k, v| lines << "- **#{k}**: #{v}" }
            lines << ""
          end

          if headers && !headers.empty?
            lines << "## Request Headers"
            headers.each { |k, v| lines << "- **#{k}**: #{v}" }
            lines << ""
          end

          req_body = req_data["request_body"]
          if req_body && !req_body.empty?
            lines << "## Request Body"
            formatted = BodyFormatter.format_body(
              profile.token,
              "request_body",
              req_body,
              req_data["request_body_encoding"],
              params
            )
            lines << formatted if formatted
            lines << ""
          end
          lines
        end

        def self.section_response(profile, params)
          lines = []

          if profile.response_headers&.any?
            lines << "## Response Headers"
            profile.response_headers.each { |k, v| lines << "- **#{k}**: #{v}" }
            lines << ""
          end

          resp_body = profile.response_body
          if resp_body && !resp_body.empty?
            lines << "## Response Body"
            formatted = BodyFormatter.format_body(
              profile.token,
              "response_body",
              resp_body,
              profile.response_body_encoding,
              params
            )
            lines << formatted if formatted
            lines << ""
          end
          lines
        end

        def self.section_curl(profile)
          req_data = profile.collector_data("request")
          lines = []
          lines << "## Curl Command"
          lines << "```bash"
          lines << generate_curl(profile, req_data)
          lines << "```"
          lines << ""
          lines
        end

        def self.section_database(profile)
          lines = []
          db_data = profile.collector_data("database")
          return lines unless db_data && db_data["total_queries"]

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
              lines << query["sql"]
              lines << "```"
              if query["backtrace"] && !query["backtrace"].empty?
                lines << "_Backtrace:_"
                query["backtrace"].first(3).each { |frame| lines << "  #{frame}" }
              end
            end
          end
          lines << ""
          lines
        end

        def self.section_performance(profile)
          lines = []
          perf_data = profile.collector_data("performance")
          return lines unless perf_data && perf_data["total_events"]

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
          lines
        end

        def self.section_views(profile)
          lines = []
          view_data = profile.collector_data("view")
          return lines unless view_data && (view_data["total_views"] || view_data["total_partials"])

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
          lines
        end

        def self.section_cache(profile)
          lines = []
          cache_data = profile.collector_data("cache")
          return lines unless cache_data && cache_data["total_reads"]

          lines << "## Cache"
          lines << "- Reads: #{cache_data['total_reads']}"
          lines << "- Writes: #{cache_data['total_writes']}"
          lines << "- Deletes: #{cache_data['total_deletes']}"
          lines << "- Hit Rate: #{cache_data['hit_rate']}%\n"

          if cache_data["reads"] && !cache_data["reads"].empty?
            lines << "### Cache Reads"
            cache_data["reads"].each do |op|
              hit_label = op["hit"] ? "HIT" : "MISS"
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
          lines
        end

        def self.section_ajax(profile)
          lines = []
          ajax_data = profile.collector_data("ajax")
          return lines unless ajax_data && ajax_data["total_requests"].to_i > 0

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
          lines
        end

        def self.section_http(profile)
          lines = []
          http_data = profile.collector_data("http")
          return lines unless http_data && http_data["total_requests"].to_i > 0

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
          lines
        end

        def self.section_routes(profile)
          lines = []
          routes_data = profile.collector_data("routes")
          return lines unless routes_data && routes_data["total"].to_i > 0

          lines << "## Routes"
          lines << "- Total routes: #{routes_data['total']}"

          matched = routes_data["matched"]
          if matched
            lines << "- **Matched:** `#{matched['verb']} #{matched['pattern']}`"
            lines << "  - Route name: #{matched['name']}_path" if matched["name"]
            lines << "  - Controller#Action: #{matched['controller_action']}" if matched["controller_action"]
          else
            lines << "- No route matched"
          end
          lines << ""
          lines
        end

        def self.section_dumps(profile)
          lines = []
          dump_data = profile.collector_data("dump")
          return lines unless dump_data && dump_data["count"].to_i > 0

          lines << "## Variable Dumps"
          lines << "- Count: #{dump_data['count']}\n"

          dump_data["dumps"]&.each_with_index do |dump, index|
            label = dump["label"] || "Dump #{index + 1}"
            location = [dump["file"], dump["line"]].compact.join(":")
            lines << "### #{label}"
            lines << "_Source: #{location}_" unless location.empty?
            lines << "```"
            lines << (dump["formatted"] || dump["value"].inspect)
            lines << "```"
          end
          lines << ""
          lines
        end

        def self.section_related_jobs(profile)
          lines = []

          # Parent info
          if profile.parent_token
            parent = Profiler.storage.load(profile.parent_token)
            if parent
              lines << "## Triggered By"
              if parent.profile_type == "job"
                job_data = parent.collector_data("job") || {}
                lines << "- **Type:** Job"
                lines << "- **Class:** #{job_data['job_class'] || parent.path}"
                lines << "- **Status:** #{job_data['status']}"
                lines << "- **Duration:** #{parent.duration.round(2)} ms"
                lines << "- **Token:** #{parent.token}"
              else
                lines << "- **Type:** HTTP Request"
                lines << "- **Request:** #{parent.method} #{parent.path}"
                lines << "- **Status:** #{parent.status}"
                lines << "- **Duration:** #{parent.duration.round(2)} ms"
                lines << "- **Token:** #{parent.token}"
              end
              lines << ""
            end
          end

          # Child jobs
          child_jobs = Profiler.storage.find_by_parent(profile.token).select { |p| p.profile_type == "job" }
          return lines if child_jobs.empty?

          lines << "## Child Jobs (#{child_jobs.size})"
          lines << ""
          lines << "| Job Class | Status | Duration | Token |"
          lines << "|-----------|--------|----------|-------|"
          child_jobs.each do |job|
            job_data = job.collector_data("job") || {}
            lines << "| #{job_data['job_class'] || job.path} | #{job_data['status'] || '-'} | #{job.duration.round(2)} ms | #{job.token} |"
          end
          lines << ""
          lines
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
