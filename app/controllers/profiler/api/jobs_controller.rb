# frozen_string_literal: true

module Profiler
  module Api
    class JobsController < ApplicationController
      def index
        render_profile_page(type: "job")
      end

      def show
        profile = Profiler.storage.load(params[:id])

        unless profile && profile.profile_type == "job"
          return render json: { error: "Job profile not found" }, status: :not_found
        end

        render json: profile.to_h.merge(
          child_jobs: build_child_jobs(profile),
          parent_profile: build_parent_summary(profile)
        )
      end

      def destroy
        profile = Profiler.storage.load(params[:id])
        return render json: { error: "Job profile not found" }, status: :not_found unless profile&.profile_type == "job"

        Profiler.storage.delete(params[:id])
        head :no_content
      end

      def clear
        Profiler.storage.clear(type: "job")
        head :no_content
      end
    end
  end
end
