# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class GetProfileAjax
        def self.call(params)
          token = params["token"]
          unless token
            return [{ type: "text", text: "Error: token parameter is required" }]
          end

          profile = Profiler.storage.load(token)
          unless profile
            return [{ type: "text", text: "Profile not found: #{token}" }]
          end

          ajax_data = profile.collector_data("ajax")
          unless ajax_data && ajax_data["total_requests"].to_i > 0
            return [{ type: "text", text: "No AJAX requests found in this profile" }]
          end

          [{ type: "text", text: format_ajax(profile, ajax_data) }]
        end

        private

        def self.format_ajax(profile, ajax_data)
          lines = []
          lines << "# AJAX Analysis: #{profile.token}\n"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Total AJAX Requests:** #{ajax_data['total_requests']}"
          lines << "**Total Duration:** #{ajax_data['total_duration'].round(2)} ms\n"

          if ajax_data["by_method"] && !ajax_data["by_method"].empty?
            lines << "## By Method"
            ajax_data["by_method"].each { |method, count| lines << "- **#{method}**: #{count}" }
            lines << ""
          end

          if ajax_data["by_status"] && !ajax_data["by_status"].empty?
            lines << "## By Status"
            ajax_data["by_status"].each { |status, count| lines << "- **#{status}**: #{count}" }
            lines << ""
          end

          if ajax_data["requests"] && !ajax_data["requests"].empty?
            lines << "## Request List"
            ajax_data["requests"].each_with_index do |req, index|
              lines << "\n### Request #{index + 1}"
              lines << "- **Method:** #{req['method']}"
              lines << "- **Path:** #{req['path']}"
              lines << "- **Status:** #{req['status']}"
              lines << "- **Duration:** #{req['duration'].round(2)} ms"
              lines << "- **Token:** #{req['token']}" if req['token']
              lines << "- **Started At:** #{req['started_at']}" if req['started_at']
            end
            lines << ""
          end

          lines.join("\n")
        end
      end
    end
  end
end
