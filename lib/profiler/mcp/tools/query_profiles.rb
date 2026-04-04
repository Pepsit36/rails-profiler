# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class QueryProfiles
        ALL_FIELDS = %w[time type method path duration queries status token].freeze

        def self.call(params)
          limit = params["limit"]&.to_i || 20
          fetch_size = [limit * 5, 500].min
          profiles = Profiler.storage.list(limit: fetch_size)

          profiles = profiles.select { |p| p.path&.include?(params["path"]) } if params["path"]
          profiles = profiles.select { |p| p.method == params["method"]&.upcase } if params["method"]
          if params["min_duration"]
            min_dur = params["min_duration"].to_f
            profiles = profiles.select { |p| p.duration && p.duration >= min_dur }
          end
          profiles = profiles.select { |p| p.profile_type == params["profile_type"] } if params["profile_type"]

          if params["cursor"]
            cutoff = Time.parse(params["cursor"]) rescue nil
            profiles = profiles.select { |p| p.started_at < cutoff } if cutoff
          end

          profiles = profiles.first(limit)
          fields = params["fields"]&.map(&:to_s)

          text = format_profiles_table(profiles, fields, limit)
          [{ type: "text", text: text }]
        end

        private

        def self.format_profiles_table(profiles, fields, limit)
          return "No profiles found matching the criteria." if profiles.empty?

          fields ||= ALL_FIELDS
          fields = fields & ALL_FIELDS  # only allow valid fields

          lines = []
          lines << "# Profiled Requests\n"
          lines << "Found #{profiles.size} profiles:\n"

          header = fields.map { |f| f.capitalize }.join(" | ")
          separator = fields.map { |_| "------" }.join("|")
          lines << "| #{header} |"
          lines << "|#{separator}|"

          profiles.each do |profile|
            db_data = profile.collector_data("database")
            query_count = db_data ? db_data["total_queries"] : 0
            type = profile.profile_type || "http"

            row = fields.map do |f|
              case f
              when "time"     then profile.started_at.strftime("%Y-%m-%d %H:%M:%S")
              when "type"     then type
              when "method"   then profile.method.to_s
              when "path"     then profile.path.to_s
              when "duration" then "#{profile.duration.round(2)}ms"
              when "queries"  then query_count.to_s
              when "status"   then profile.status.to_s
              when "token"    then profile.token.to_s
              end
            end
            lines << "| #{row.join(' | ')} |"
          end

          if profiles.size == limit
            lines << ""
            lines << "*Next cursor: #{profiles.last.started_at.iso8601}*"
          end

          lines.join("\n")
        end
      end
    end
  end
end
