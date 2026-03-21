# frozen_string_literal: true

module Profiler
  module Api
    class ProfilesController < ApplicationController
      skip_before_action :verify_authenticity_token

      def index
        profiles = Profiler.storage.list(limit: params[:limit] || 50, offset: params[:offset] || 0)
        render json: profiles.map(&:to_h)
      end

      def show
        profile = Profiler.storage.load(params[:id])

        unless profile
          return render json: { error: "Profile not found" }, status: :not_found
        end

        # Recalculate AJAX collector data (since AJAX requests happen after page load)
        recalculate_ajax_data(profile)

        render json: profile.to_h
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

      def recalculate_ajax_data(profile)
        # Find AJAX collector in the configured collectors
        ajax_collector_class = Profiler::Collectors::AjaxCollector

        if Profiler.configuration.collectors.include?(ajax_collector_class)
          collector = ajax_collector_class.new(profile)
          collector.collect

          # Update tab metadata to reflect has_data status
          if profile.instance_variable_get(:@collectors_metadata)
            ajax_tab = profile.instance_variable_get(:@collectors_metadata).find { |tab| tab[:key] == 'ajax' }
            if ajax_tab
              ajax_tab[:has_data] = collector.has_data?
            end
          end
        end
      end
    end
  end
end
