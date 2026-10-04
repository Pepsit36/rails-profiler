# frozen_string_literal: true

module Profiler
  module Api
    class ToolbarController < Profiler::ApplicationController
      def show
        profile = Profiler.storage.load(params[:token])

        unless profile
          render json: { error: "Profile not found" }, status: :not_found
          return
        end

        # Recalculate AJAX collector data (since AJAX requests happen after page load)
        recalculate_ajax_data(profile)

        render json: { profile: profile.to_h.merge(child_jobs: build_child_jobs(profile)) }
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
