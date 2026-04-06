# frozen_string_literal: true

module Profiler
  module Api
    class JobsController < ApplicationController
      skip_before_action :verify_authenticity_token

      def index
        limit  = (params[:limit]  || 50).to_i
        offset = (params[:offset] || 0).to_i
        all    = Profiler.storage.list(limit: 1000, offset: 0)
        jobs   = all.select { |p| p.profile_type == "job" }
        page   = jobs.drop(offset).first(limit + 1)
        render json: {
          profiles: page.first(limit).map(&:to_h),
          limit:    limit,
          offset:   offset,
          has_more: page.size > limit
        }
      end

      def show
        profile = Profiler.storage.load(params[:id])

        unless profile && profile.profile_type == "job"
          return render json: { error: "Job profile not found" }, status: :not_found
        end

        render json: profile.to_h
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
