# frozen_string_literal: true

require "shellwords"
require "uri"

module Profiler
  module MCP
    module Tools
      class GetProfileHttp
        def self.call(params)
          token = params["token"]
          unless token
            return [{ type: "text", text: "Error: token parameter is required" }]
          end

          profile = if token == "latest"
            Profiler.storage.list(limit: 1).first
          else
            Profiler.storage.load(token)
          end
          unless profile
            return [{ type: "text", text: "Profile not found: #{token}" }]
          end

          http_data = profile.collector_data("http")
          unless http_data && http_data["total_requests"].to_i > 0
            return [{ type: "text", text: "No outbound HTTP requests found in this profile" }]
          end

          domain_filter = params["domain"]
          [{ type: "text", text: format_http(profile, http_data, domain_filter, params) }]
        end

        private

        def self.format_http(profile, http_data, domain_filter, params)
          threshold = Profiler.configuration.slow_http_threshold
          requests = http_data["requests"] || []

          if domain_filter && !domain_filter.empty?
            requests = requests.select do |req|
              host = begin
                URI.parse(req["url"]).host.to_s
              rescue URI::InvalidURIError
                ""
              end
              host.include?(domain_filter)
            end
          end

          lines = []
          lines << "# Outbound HTTP Analysis: #{profile.token}\n"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Started at:** #{profile.started_at&.strftime('%Y-%m-%d %H:%M:%S')}"
          lines << "**Total Outbound Requests:** #{http_data['total_requests']}"
          lines << "**Showing:** #{requests.size} request(s)#{domain_filter ? " (filtered by domain: #{domain_filter})" : ""}"
          lines << "**Total Duration:** #{http_data['total_duration'].round(2)} ms"
          lines << "**Slow Requests (>#{threshold}ms):** #{http_data['slow_requests']}"
          lines << "**Error Requests:** #{http_data['error_requests']}\n"

          if http_data["by_host"] && !http_data["by_host"].empty? && !domain_filter
            lines << "## By Host"
            http_data["by_host"].each { |host, count| lines << "- **#{host}**: #{count}" }
            lines << ""
          end

          if http_data["by_status"] && !http_data["by_status"].empty? && !domain_filter
            lines << "## By Status"
            http_data["by_status"].each { |status, count| lines << "- **#{status}**: #{count}" }
            lines << ""
          end

          if requests && !requests.empty?
            lines << "## Request Details"
            requests.each_with_index do |req, i|
              slow_flag = req["duration"] >= threshold ? " [SLOW]" : ""
              err_flag = req["status"] >= 400 || req["status"] == 0 ? " [ERROR]" : ""
              lines << "\n### Request #{i + 1}#{slow_flag}#{err_flag}"
              lines << "- **ID:** #{req['id']}" if req["id"]
              lines << "- **Started at:** #{req['started_at']}" if req["started_at"]
              lines << "- **Method:** #{req['method']}"
              lines << "- **URL:** #{req['url']}"
              lines << "- **Status:** #{req['status'] == 0 ? 'connection error' : req['status']}"
              lines << "- **Duration:** #{req['duration'].round(2)} ms"
              lines << "- **Request Size:** #{req['request_size']} bytes"
              lines << "- **Response Size:** #{req['response_size']} bytes"
              lines << "- **Error:** #{req['error']}" if req["error"]

              if req["request_headers"] && !req["request_headers"].empty?
                lines << "- **Request Headers:**"
                req["request_headers"].each { |k, v| lines << "  - `#{k}`: #{v}" }
              end

              if req["request_body"] && !req["request_body"].empty?
                lines << "- **Request Body:**"
                formatted = BodyFormatter.format_body(
                  profile.token,
                  "http_#{i}_request_body",
                  req["request_body"],
                  req["request_body_encoding"],
                  params
                )
                lines << formatted if formatted
              end

              if req["response_headers"] && !req["response_headers"].empty?
                lines << "- **Response Headers:**"
                req["response_headers"].each { |k, v| lines << "  - `#{k}`: #{v}" }
              end

              if req["response_body"] && !req["response_body"].empty?
                lines << "- **Response Body:**"
                formatted = BodyFormatter.format_body(
                  profile.token,
                  "http_#{i}_response_body",
                  req["response_body"],
                  req["response_body_encoding"],
                  params
                )
                lines << formatted if formatted
              end

              if req["backtrace"] && !req["backtrace"].empty?
                lines << "- **Called from:**"
                req["backtrace"].first(3).each { |frame| lines << "  - #{frame}" }
              end
              lines << "- **Curl:**"
              lines << "  ```bash"
              lines << "  #{generate_curl_for_outbound(req)}"
              lines << "  ```"
            end
            lines << ""
          end

          lines.join("\n")
        end

        def self.generate_curl_for_outbound(req)
          parts = ["curl -X #{req['method']}"]
          req["request_headers"]
            &.reject { |k, _| k.downcase == "user-agent" }
            &.each { |k, v| parts << "  -H #{Shellwords.shellescape("#{k}: #{v}")}" }
          if req["request_body"] && !req["request_body"].empty? && req["request_body_encoding"] != "base64"
            parts << "  -d #{Shellwords.shellescape(req['request_body'])}"
          end
          parts << "  #{Shellwords.shellescape(req['url'])}"
          parts.join(" \\\n")
        end
      end
    end
  end
end
