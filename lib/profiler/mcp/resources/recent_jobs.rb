# frozen_string_literal: true

module Profiler
  module MCP
    module Resources
      class RecentJobs
        def self.call
          profiles = Profiler.storage.list(limit: 200)
          jobs = profiles.select { |p| p.profile_type == "job" }.first(50)

          data = jobs.map do |profile|
            job_data = profile.collector_data("job") || {}
            {
              token: profile.token,
              job_class: job_data["job_class"] || profile.path,
              job_id: job_data["job_id"],
              queue: job_data["queue"],
              status: job_data["status"],
              duration: profile.duration&.round(2),
              executions: job_data["executions"],
              error: job_data["error"],
              timestamp: profile.started_at&.iso8601,
              query_count: profile.collector_data("database")&.dig("total_queries") || 0
            }
          end

          {
            uri: "profiler://recent-jobs",
            mimeType: "application/json",
            text: JSON.pretty_generate({
              total: data.size,
              jobs: data
            })
          }
        end
      end
    end
  end
end
