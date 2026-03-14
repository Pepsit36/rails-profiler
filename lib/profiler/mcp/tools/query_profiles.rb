# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class QueryProfiles
        def self.call(params)
          limit = params["limit"]&.to_i || 20
          profiles = Profiler.storage.list(limit: limit)

          # Apply filters
          if params["path"]
            profiles = profiles.select { |p| p.path&.include?(params["path"]) }
          end

          if params["method"]
            profiles = profiles.select { |p| p.method == params["method"]&.upcase }
          end

          if params["min_duration"]
            min_dur = params["min_duration"].to_f
            profiles = profiles.select { |p| p.duration && p.duration >= min_dur }
          end

          # Format as markdown table
          text = format_profiles_table(profiles)

          [
            {
              type: "text",
              text: text
            }
          ]
        end

        private

        def self.format_profiles_table(profiles)
          if profiles.empty?
            return "No profiles found matching the criteria."
          end

          lines = []
          lines << "# Profiled Requests\n"
          lines << "Found #{profiles.size} profiles:\n"
          lines << "| Time | Method | Path | Duration | Queries | Status | Token |"
          lines << "|------|--------|------|----------|---------|--------|-------|"

          profiles.each do |profile|
            db_data = profile.collector_data("database")
            query_count = db_data ? db_data["total_queries"] : 0

            lines << "| #{profile.started_at.strftime('%H:%M:%S')} | #{profile.method} | #{profile.path} | #{profile.duration.round(2)}ms | #{query_count} | #{profile.status} | #{profile.token[0..7]}... |"
          end

          lines.join("\n")
        end
      end
    end
  end
end
