# frozen_string_literal: true

require_relative "../../../lib/profiler/cluster/slave_proxy"

module Profiler
  class ProfilesController < ApplicationController
    def index
      limit = params[:limit]&.to_i || 50
      offset = params[:offset]&.to_i || 0

      @profiles = Profiler.storage.list(limit: limit, offset: offset)
      @profiles = filter_profiles(@profiles) if params[:filter].present?
    end

    def show
      @profile = resolve_profile(params[:id])

      unless @profile
        render plain: "Profile not found", status: :not_found
        return
      end

      # Recalculate AJAX collector data (since AJAX requests happen after page load)
      recalculate_ajax_data(@profile)
      # The route table and ENV are the process's, not stored in the profile
      Profiler::ProcessSnapshot.hydrate(@profile)

      @profile_data = @profile.to_h.merge(
        child_jobs: build_child_jobs(@profile),
        parent_profile: build_parent_summary(@profile)
      )

      @embedded = params[:embed] == "true"

      render layout: @embedded ? "profiler/embedded" : "profiler/application"
    end

    def timeline
      @profile = resolve_profile(params[:id])
      return render plain: "Profile not found", status: :not_found unless @profile

      render json: @profile.collector_data("performance")
    end

    def database
      @profile = resolve_profile(params[:id])
      return render plain: "Profile not found", status: :not_found unless @profile

      render json: @profile.collector_data("database")
    end

    def views
      @profile = resolve_profile(params[:id])
      return render plain: "Profile not found", status: :not_found unless @profile

      render json: @profile.collector_data("view")
    end

    def cache
      @profile = resolve_profile(params[:id])
      return render plain: "Profile not found", status: :not_found unless @profile

      render json: @profile.collector_data("cache")
    end

    def performance
      @profile = resolve_profile(params[:id])
      return render plain: "Profile not found", status: :not_found unless @profile

      render json: @profile.collector_data("performance")
    end

    def flamegraph
      @profile = resolve_profile(params[:id])
      return render plain: "Profile not found", status: :not_found unless @profile

      render json: @profile.collector_data("flamegraph")
    end

    private

    # Resolves a profile token against local storage first, then online slaves.
    # Sets @resolved_storage to the storage that owns the profile so that
    # secondary lookups (child jobs, parent, AJAX) go to the same node.
    def resolve_profile(token)
      # Local storage — fast path, covers master-owned profiles
      if (profile = Profiler.storage.load(token))
        @resolved_storage = Profiler.storage
        return profile
      end

      # Cache hit — skip fan-out if we already know which slave has this token
      if (cached_slave = Profiler.token_cache.fetch(token))
        entry = Profiler.slave_registry.all.find { |e| e[:name] == cached_slave }
        if entry && entry[:status] == "online"
          begin
            proxy = Cluster::SlaveProxy.new(cached_slave, open_timeout: 2, read_timeout: 3)
            if (profile = proxy.load(token))
              @resolved_storage = proxy
              return profile
            end
          rescue => e
            Rails.logger.warn("[Profiler] Cached slave #{cached_slave} failed for #{token}: #{e.message}")
          end
        end
        Profiler.token_cache.invalidate(token)
      end

      # Parallel fan-out across all online slaves
      online_slaves = Profiler.slave_registry.online_names
      return nil if online_slaves.empty?

      found_profile  = nil
      found_proxy    = nil
      found_slave    = nil
      result_mutex   = Mutex.new

      threads = online_slaves.map do |slave_name|
        Thread.new do
          begin
            proxy   = Cluster::SlaveProxy.new(slave_name, open_timeout: 2, read_timeout: 3)
            profile = proxy.load(token)
            if profile
              result_mutex.synchronize do
                unless found_profile
                  found_profile = profile
                  found_proxy   = proxy
                  found_slave   = slave_name
                end
              end
            end
          rescue => e
            Rails.logger.warn("[Profiler] Fan-out error for slave #{slave_name} (#{token}): #{e.message}")
          end
        end
      end

      threads.each(&:join)

      if found_profile
        Profiler.token_cache.store(token, found_slave)
        @resolved_storage = found_proxy
        found_profile
      end
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
