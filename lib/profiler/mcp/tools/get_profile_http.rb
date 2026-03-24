# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class GetProfileHttp
        def self.call(params)
          token = params["token"]
          unless token
            return [{ type: "text", text: "Error: token parameter is required" }]
          end

          profile = Profiler.storage.load(token)
          unless profile
            return [{ type: "text", text: "Profile not found: #{token}" }]
          end

          http_data = profile.collector_data("http")
          unless http_data && http_data["total_requests"].to_i > 0
            return [{ type: "text", text: "No outbound HTTP requests found in this profile" }]
          end

          [{ type: "text", text: format_http(profile, http_data) }]
        end

        private

        def self.format_http(profile, http_data)
          threshold = Profiler.configuration.slow_http_threshold
          lines = []
          lines << "# Outbound HTTP Analysis: #{profile.token}\n"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Total Outbound Requests:** #{http_data['total_requests']}"
          lines << "**Total Duration:** #{http_data['total_duration'].round(2)} ms"
          lines << "**Slow Requests (>#{threshold}ms):** #{http_data['slow_requests']}"
          lines << "**Error Requests:** #{http_data['error_requests']}\n"

          if http_data["by_host"] && !http_data["by_host"].empty?
            lines << "## By Host"
            http_data["by_host"].each { |host, count| lines << "- **#{host}**: #{count}" }
            lines << ""
          end

          if http_data["by_status"] && !http_data["by_status"].empty?
            lines << "## By Status"
            http_data["by_status"].each { |status, count| lines << "- **#{status}**: #{count}" }
            lines << ""
          end

          if http_data["requests"] && !http_data["requests"].empty?
            lines << "## Request Details"
            http_data["requests"].each_with_index do |req, i|
              slow_flag = req["duration"] >= threshold ? " [SLOW]" : ""
              err_flag = req["status"] >= 400 || req["status"] == 0 ? " [ERROR]" : ""
              lines << "\n### Request #{i + 1}#{slow_flag}#{err_flag}"
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
                if req["request_body_encoding"] == "base64"
                  lines << "  *(binary content, base64 encoded — #{req['request_body'].bytesize} chars)*"
                else
                  lines << "  ```"
                  lines << "  #{req['request_body'].lines.first(5).join('  ')}"
                  lines << "  ```"
                end
              end
              if req["response_headers"] && !req["response_headers"].empty?
                lines << "- **Response Headers:**"
                req["response_headers"].each { |k, v| lines << "  - `#{k}`: #{v}" }
              end
              if req["response_body"] && !req["response_body"].empty?
                lines << "- **Response Body:**"
                if req["response_body_encoding"] == "base64"
                  lines << "  *(binary content, base64 encoded — #{req['response_body'].bytesize} chars)*"
                else
                  lines << "  ```"
                  lines << "  #{req['response_body'].lines.first(10).join('  ')}"
                  lines << "  ```"
                end
              end
              if req["backtrace"] && !req["backtrace"].empty?
                lines << "- **Called from:**"
                req["backtrace"].first(3).each { |frame| lines << "  - #{frame}" }
              end
            end
            lines << ""
          end

          lines.join("\n")
        end
      end
    end
  end
end
