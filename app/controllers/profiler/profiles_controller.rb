# frozen_string_literal: true

module Profiler
  class ProfilesController < ApplicationController
    before_action :allow_iframe_embedding, only: [:show], if: -> { params[:embed] == "true" }

    def index
      limit = params[:limit]&.to_i || 50
      offset = params[:offset]&.to_i || 0

      @profiles = Profiler.storage.list(limit: limit, offset: offset)
      @profiles = filter_profiles(@profiles) if params[:filter].present?
    end

    def show
      @profile = Profiler.storage.load(params[:id])

      unless @profile
        render plain: "Profile not found", status: :not_found
        return
      end

      # Recalculate AJAX collector data (since AJAX requests happen after page load)
      recalculate_ajax_data(@profile)

      @embedded = params[:embed] == "true"

      render layout: @embedded ? "profiler/embedded" : "profiler/application"
    end

    def timeline
      @profile = Profiler.storage.load(params[:id])
      render json: @profile.collector_data("performance")
    end

    def database
      @profile = Profiler.storage.load(params[:id])
      render json: @profile.collector_data("database")
    end

    def views
      @profile = Profiler.storage.load(params[:id])
      render json: @profile.collector_data("view")
    end

    def cache
      @profile = Profiler.storage.load(params[:id])
      render json: @profile.collector_data("cache")
    end

    def performance
      @profile = Profiler.storage.load(params[:id])
      render json: @profile.collector_data("performance")
    end

    def flamegraph
      @profile = Profiler.storage.load(params[:id])
      render json: @profile.collector_data("flamegraph")
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

    def allow_iframe_embedding
      response.headers.delete('X-Frame-Options')
      # Don't set frame-ancestors CSP to allow Chrome extensions to embed
      # Mark that CSP should not be set by middleware
      request.env['profiler.skip_csp'] = true
    end

    def filter_profiles(profiles)
      filtered = profiles

      if params[:filter][:path].present?
        filtered = filtered.select { |p| p.path.include?(params[:filter][:path]) }
      end

      if params[:filter][:method].present?
        filtered = filtered.select { |p| p.method == params[:filter][:method] }
      end

      if params[:filter][:min_duration].present?
        min = params[:filter][:min_duration].to_f
        filtered = filtered.select { |p| p.duration >= min }
      end

      filtered
    end
  end
end
