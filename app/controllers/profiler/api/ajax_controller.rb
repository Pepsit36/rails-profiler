# frozen_string_literal: true

module Profiler
  module Api
    class AjaxController < ApplicationController
      def link
        parent_token = params[:parent_token]
        child_token = params[:child_token]

        # Validate parameters
        if parent_token.blank? || child_token.blank?
          return render json: { error: "Missing parent_token or child_token" }, status: :bad_request
        end

        # Load child profile
        child_profile = Profiler.storage.load(child_token)
        unless child_profile
          return render json: { error: "Child profile not found" }, status: :not_found
        end

        # Set parent relationship
        child_profile.parent_token = parent_token
        child_profile.is_ajax = true

        # Save updated profile
        Profiler.storage.save(child_token, child_profile)

        render json: { success: true }
      rescue => e
        render json: { error: e.message }, status: :internal_server_error
      end
    end
  end
end
