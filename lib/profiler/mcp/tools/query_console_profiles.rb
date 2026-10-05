# frozen_string_literal: true

require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class QueryConsoleProfiles
        ALL_FIELDS = %w[time expression return_value status duration queries token].freeze

        def self.call(params)
          limit = params["limit"]&.to_i || 20
          fetch_size = [limit * 5, 500].min
          storage = MCP::SlaveSupport.resolve_storage(params)
          profiles = storage.list(limit: fetch_size, type: "console")

          consoles = profiles.select { |p| p.profile_type == "console" }

          if params["expression"]
            term = params["expression"].downcase
            consoles = consoles.select do |p|
              console_data = p.collector_data("console")
              console_data && console_data["expression"].to_s.downcase.include?(term)
            end
          end

          if params["status"]
            consoles = consoles.select do |p|
              case params["status"]
              when "completed" then p.status == 200
              when "failed"    then p.status != 200
              else false
              end
            end
          end

          if params["min_duration"]
            min_ms = params["min_duration"].to_f
            consoles = consoles.select { |p| p.duration >= min_ms }
          end

          if params["cursor"]
            cutoff = begin
              Time.parse(params["cursor"])
            rescue ArgumentError, TypeError
              nil # a cursor that is not a time is ignored, as before
            end
            consoles = consoles.select { |p| p.started_at < cutoff } if cutoff
          end

          consoles = consoles.first(limit)
          fields = params["fields"]&.map(&:to_s)

          [{ type: "text", text: format_console_table(consoles, fields, limit) }]
        end

        private

        def self.format_console_table(consoles, fields, limit)
          return "No console profiles found matching the criteria." if consoles.empty?

          fields ||= ALL_FIELDS
          fields = fields & ALL_FIELDS

          lines = []
          lines << "# Console Profiles\n"
          lines << "Found #{consoles.size} console execution#{consoles.size > 1 ? "s" : ""}:\n"

          header = fields.map { |f| f.split("_").map(&:capitalize).join(" ") }.join(" | ")
          separator = fields.map { "------" }.join("|")
          lines << "| #{header} |"
          lines << "|#{separator}|"

          consoles.each do |profile|
            console_data = profile.collector_data("console") || {}
            db_data = profile.collector_data("database") || {}

            row = fields.map do |f|
              case f
              when "time"         then profile.started_at&.strftime("%H:%M:%S") || "-"
              when "expression"   then console_data["expression"].to_s.then { |e| e.length > 60 ? "#{e[0, 57]}..." : e }
              when "return_value" then console_data["return_value"].to_s.then { |v| v.length > 80 ? "#{v[0, 77]}..." : v }
              when "status"       then profile.status == 200 ? "completed" : "failed"
              when "duration"     then profile.duration ? "#{profile.duration.round(2)}ms" : "-"
              when "queries"      then db_data["total_queries"].to_i.to_s
              when "token"        then profile.token.to_s
              end
            end
            lines << "| #{row.join(' | ')} |"
          end

          if consoles.size == limit
            lines << ""
            lines << "*Next cursor: #{consoles.last.started_at.iso8601}*"
          end

          lines.join("\n")
        end
      end
    end
  end
end
