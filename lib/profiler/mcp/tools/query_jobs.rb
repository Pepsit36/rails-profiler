# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class QueryJobs
        def self.call(params)
          limit = params["limit"]&.to_i || 20
          profiles = Profiler.storage.list(limit: [limit * 5, 200].min)

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

          jobs = jobs.first(limit)

          text = format_jobs_table(jobs)

          [{ type: "text", text: text }]
        end

        private

        def self.format_jobs_table(jobs)
          if jobs.empty?
            return "No job profiles found matching the criteria."
          end

          lines = []
          lines << "# Background Job Profiles\n"
          lines << "Found #{jobs.size} jobs:\n"
          lines << "| Time | Job Class | Queue | Status | Duration | Token |"
          lines << "|------|-----------|-------|--------|----------|-------|"

          jobs.each do |profile|
            job_data = profile.collector_data("job") || {}
            job_class = job_data["job_class"] || profile.path
            queue = job_data["queue"] || "-"
            status = job_data["status"] || "-"
            lines << "| #{profile.started_at.strftime('%H:%M:%S')} | #{job_class} | #{queue} | #{status} | #{profile.duration.round(2)}ms | #{profile.token} |"
          end

          lines.join("\n")
        end
      end
    end
  end
end
