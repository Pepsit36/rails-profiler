# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class GetProfileDumps
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

          dump_data = profile.collector_data("dump")
          unless dump_data && dump_data["count"].to_i > 0
            return [{ type: "text", text: "No variable dumps found in this profile" }]
          end

          [{ type: "text", text: format_dumps(profile, dump_data) }]
        end

        private

        def self.format_dumps(profile, dump_data)
          lines = []
          lines << "# Variable Dumps: #{profile.token}\n"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Total Dumps:** #{dump_data['count']}\n"

          dump_data["dumps"]&.each_with_index do |dump, index|
            label = dump['label'] || "Dump #{index + 1}"
            location = [dump['file'], dump['line']].compact.join(':')

            lines << "## #{label}"
            lines << "- **Source:** #{location}" unless location.empty?
            lines << "- **Timestamp:** #{dump['timestamp']}" if dump['timestamp']
            lines << "\n```"
            lines << (dump['formatted'] || dump['value'].inspect)
            lines << "```\n"
          end

          lines.join("\n")
        end
      end
    end
  end
end
