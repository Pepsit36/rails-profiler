# frozen_string_literal: true

module Profiler
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "profiler/application"

    before_action :check_authorization

    private

    def check_authorization
      unless Profiler.configuration.enabled
        render plain: "Profiler is disabled", status: :forbidden
      end
    end

    def build_child_jobs(profile)
      Profiler.storage.find_by_parent(profile.token)
               .select { |p| p.profile_type == "job" }
               .map do |j|
                 job_data = j.collector_data("job") || {}
                 {
                   token: j.token,
                   job_class: j.path,
                   job_id: job_data["job_id"],
                   queue: job_data["queue"],
                   status: job_data["status"],
                   duration: j.duration,
                   started_at: j.started_at&.iso8601
                 }
               end
    end

    def build_parent_summary(profile)
      return nil unless profile.parent_token

      parent = Profiler.storage.load(profile.parent_token)
      return nil unless parent

      if parent.profile_type == "job"
        job_data = parent.collector_data("job") || {}
        {
          token: parent.token,
          profile_type: "job",
          path: parent.path,
          status: job_data["status"],
          duration: parent.duration,
          started_at: parent.started_at&.iso8601
        }
      else
        {
          token: parent.token,
          profile_type: "http",
          method: parent.method,
          path: parent.path,
          http_status: parent.status,
          duration: parent.duration,
          started_at: parent.started_at&.iso8601
        }
      end
    end
  end
end
