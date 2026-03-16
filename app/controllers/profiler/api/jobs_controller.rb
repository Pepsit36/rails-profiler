# frozen_string_literal: true

module Profiler
  module Api
    class JobsController < ApplicationController
      skip_before_action :verify_authenticity_token

      def index
        all_profiles = Profiler.storage.list(limit: (params[:limit] || 200).to_i, offset: (params[:offset] || 0).to_i)
        job_profiles = all_profiles.select { |p| p.profile_type == "job" }
        job_profiles = job_profiles.first((params[:limit] || 50).to_i)
        render json: job_profiles.map(&:to_h)
      end

      def show
        profile = Profiler.storage.load(params[:id])

        unless profile && profile.profile_type == "job"
          return render json: { error: "Job profile not found" }, status: :not_found
        end

        render json: profile.to_h
      end
    end
  end
end
