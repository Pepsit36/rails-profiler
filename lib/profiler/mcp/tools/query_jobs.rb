# frozen_string_literal: true

require_relative "../slave_support"

module Profiler
  module MCP
    module Tools
      class QueryJobs
        ALL_FIELDS = %w[time job_class queue status duration gem_version token parent_token].freeze

        def self.call(params)
          limit = params["limit"]&.to_i || 20
          fetch_size = [limit * 5, 500].min
          storage = MCP::SlaveSupport.resolve_storage(params)
          profiles = storage.list(limit: fetch_size)

          jobs = profiles.select { |p| p.profile_type == "job" }

          if params["queue"]
            jobs = jobs.select do |p|
              job_data = p.collector_data("job")
              job_data && job_data["queue"] == params["queue"]
            end
          end

          if params["status"]
            jobs = jobs.select do |p|
              job_data = p.collector_data("job")
              job_data && job_data["status"] == params["status"]
            end
          end

          if params["cursor"]
            cutoff = Time.parse(params["cursor"]) rescue nil
            jobs = jobs.select { |p| p.started_at < cutoff } if cutoff
          end

          jobs = jobs.first(limit)
          fields = params["fields"]&.map(&:to_s)

          [{ type: "text", text: format_jobs_table(jobs, fields, limit) }]
        end

        private

        def self.format_jobs_table(jobs, fields, limit)
          return "No job profiles found matching the criteria." if jobs.empty?

          fields ||= ALL_FIELDS
          fields = fields & ALL_FIELDS

          lines = []
          lines << "# Background Job Profiles\n"
          lines << "Found #{jobs.size} jobs:\n"

          header = fields.map { |f| f.split("_").map(&:capitalize).join(" ") }.join(" | ")
          separator = fields.map { |_| "------" }.join("|")
          lines << "| #{header} |"
          lines << "|#{separator}|"

          jobs.each do |profile|
            job_data = profile.collector_data("job") || {}
            row = fields.map do |f|
              case f
              when "time"         then profile.started_at&.strftime("%H:%M:%S") || "-"
              when "job_class"    then job_data["job_class"] || profile.path
              when "queue"        then job_data["queue"] || "-"
              when "status"       then job_data["status"] || "-"
              when "duration"     then profile.duration ? "#{profile.duration.round(2)}ms" : "-"
              when "gem_version"
                v = profile.gem_version || "-"
                v != Profiler::VERSION ? "#{v} ⚠️" : v
              when "token"        then profile.token.to_s
              when "parent_token" then profile.parent_token || "-"
              end
            end
            lines << "| #{row.join(' | ')} |"
          end

          if jobs.size == limit
            lines << ""
            lines << "*Next cursor: #{jobs.last.started_at.iso8601}*"
          end

          lines.join("\n")
        end
      end
    end
  end
end
