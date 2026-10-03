# frozen_string_literal: true

module Profiler
  class ApplicationController < ActionController::Base
    layout "profiler/application"

    before_action :check_authorization
    before_action :authorize_request
    # Declared after the access checks, so that an unauthorized request gets its 403 first.
    protect_from_forgery with: :exception

    private

    def check_authorization
      unless Profiler.configuration.enabled
        render plain: "Profiler is disabled", status: :forbidden
      end
    end

    def authorize_request
      return if Profiler.configuration.authorized?(request)

      deny("Not authorized to access the profiler")
    end

    # Rails' token, or the header every profiler client sends. A third-party page cannot add a
    # custom header without a CORS preflight, which is refused unless an origin was allowed.
    def verified_request?
      super ||
        !Profiler.configuration.api_forgery_protection ||
        request.headers[Profiler::FORGERY_PROTECTION_HEADER].present?
    end

    def handle_unverified_request
      deny("Missing #{Profiler::FORGERY_PROTECTION_HEADER} header or CSRF token")
    end

    def deny(message)
      if controller_path.start_with?("profiler/api/")
        render json: { error: message }, status: :forbidden
      else
        render plain: message, status: :forbidden
      end
    end

    def build_child_jobs(profile)
      storage = @resolved_storage || Profiler.storage
      storage.find_by_parent(profile.token)
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

      storage = @resolved_storage || Profiler.storage
      parent  = storage.load(profile.parent_token)
      # Cross-node fallback: parent may live on the master when the profile is on a slave
      parent ||= Profiler.storage.load(profile.parent_token) if storage != Profiler.storage
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
