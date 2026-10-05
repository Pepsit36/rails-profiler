# frozen_string_literal: true

require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class QueryMailers
        ALL_FIELDS = %w[time mailer action subject to mode duration status token].freeze

        class << self
          def call(params)
            limit = params["limit"]&.to_i || 20
            fetch_size = [limit * 10, 1000].min
            storage = MCP::SlaveSupport.resolve_storage(params)
            profiles = storage.list(limit: fetch_size)

            emails = []

            profiles.each do |profile|
              mailer_data = profile.collector_data("mailer")
              next unless mailer_data

              all_emails = Array(mailer_data["emails"]) + Array(mailer_data["errors"])
              all_emails.each do |email|
                entry = email.merge("profile_token" => profile.token, "profile_started_at" => profile.started_at)

                if params["mailer_class"]
                  next unless entry["mailer_class"].to_s.downcase.include?(params["mailer_class"].downcase)
                end

                if params["action"]
                  next unless entry["action"].to_s.downcase.include?(params["action"].downcase)
                end

                if params["delivery_mode"]
                  next unless entry["delivery_mode"] == params["delivery_mode"]
                end

                if params["has_error"]
                  has_err = !entry["error"].nil?
                  next unless has_err == (params["has_error"] == true || params["has_error"] == "true")
                end

                emails << entry
              end

              break if emails.size >= limit * 2
            end

            if params["cursor"]
              cutoff = begin
                Time.parse(params["cursor"])
              rescue ArgumentError, TypeError
                nil # a cursor that is not a time is ignored, as before
              end
              if cutoff
                emails = emails.select do |e|
                  started = e["profile_started_at"]
                  started && started < cutoff
                end
              end
            end

            emails = emails.first(limit)

            [{ type: "text", text: format_mailers_table(emails, params["fields"]&.map(&:to_s), limit) }]
          end

          private

          def format_mailers_table(emails, fields, limit)
            return "No mailer deliveries found matching the criteria." if emails.empty?

            fields ||= ALL_FIELDS
            fields = fields & ALL_FIELDS

            lines = []
            lines << "# Mailer Deliveries\n"
            lines << "Found #{emails.size} email#{emails.size > 1 ? "s" : ""}:\n"

            header = fields.map { |f| f.split("_").map(&:capitalize).join(" ") }.join(" | ")
            separator = fields.map { "------" }.join("|")
            lines << "| #{header} |"
            lines << "|#{separator}|"

            emails.each do |email|
              started = email["profile_started_at"]
              to_list = Array(email["to"]).first(2).join(", ")
              to_list += ", …" if Array(email["to"]).size > 2
              status = email["error"] ? "❌ Error" : "✅"

              row = fields.map do |f|
                case f
                when "time"     then started ? started.strftime("%H:%M:%S") : "-"
                when "mailer"   then email["mailer_class"].to_s
                when "action"   then email["action"].to_s
                when "subject"  then (email["subject"].to_s)[0, 40]
                when "to"       then to_list
                when "mode"     then email["delivery_mode"].to_s
                when "duration" then email["duration_ms"] ? "#{email["duration_ms"]}ms" : "-"
                when "status"   then status
                when "token"    then email["profile_token"].to_s
                end
              end
              lines << "| #{row.join(" | ")} |"
            end

            if emails.size == limit
              last_started = emails.last["profile_started_at"]
              lines << ""
              lines << "*Next cursor: #{last_started.iso8601}*" if last_started
            end

            lines.join("\n")
          end
        end
      end
    end
  end
end
