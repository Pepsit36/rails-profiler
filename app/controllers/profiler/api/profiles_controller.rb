# frozen_string_literal: true

module Profiler
  module Api
    class ProfilesController < ApplicationController
      def index
        # all_types is an opt-in used by the cluster proxy so it can mirror the full
        # storage.list contract (every type, or the one given as type, full profiles); the
        # dashboard relies on the default: http profiles, as summaries.
        if params[:parent_token].present?
          render_children_page
        elsif all_types?
          render_profile_page(type: profile_type_param, summary: false)
        else
          render_profile_page(type: "http")
        end
      end

      def show
        profile = Profiler.storage.load(params[:id])

        unless profile
          return render json: { error: "Profile not found" }, status: :not_found
        end

        # Recalculate AJAX collector data (since AJAX requests happen after page load)
        recalculate_ajax_data(profile)
        # The route table and ENV are the process's, not stored in the profile
        Profiler::ProcessSnapshot.hydrate(profile)

        render json: profile.to_h.merge(
          child_jobs: build_child_jobs(profile),
          parent_profile: build_parent_summary(profile)
        )
      end

      def destroy
        profile = Profiler.storage.load(params[:id])
        return render json: { error: "Profile not found" }, status: :not_found unless profile

        Profiler.storage.delete(params[:id])
        head :no_content
      end

      def clear
        Profiler.storage.clear(type: "http")
        head :no_content
      end

      private

      def all_types?
        %w[1 true].include?(params[:all_types].to_s)
      end

      def profile_type_param
        params[:type].to_s.match?(/\A[a-z_]{1,32}\z/) ? params[:type].to_s : nil
      end

      # The children of a page, oldest last, read through the store's parent index.
      def render_children_page
        limit, offset = page_params
        children = Profiler.storage.find_by_parent(params[:parent_token].to_s).reverse
        children = children.select { |p| p.profile_type == "http" } unless all_types?
        render_page(children.drop(offset).first(limit + 1), limit, offset)
      end
    end
  end
end
