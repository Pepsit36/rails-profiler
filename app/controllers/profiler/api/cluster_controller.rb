# frozen_string_literal: true

module Profiler
  module Api
    class ClusterController < Profiler::ApplicationController
      def register
        name = params[:name].to_s
        url  = params[:url].to_s

        if name.empty? || url.empty?
          return render json: { error: "name and url are required" }, status: :unprocessable_entity
        end

        Profiler.slave_registry.register(name: name, url: url)
        render json: { ok: true, name: name }
      end

      def heartbeat
        name = params[:name].to_s
        entry = Profiler.slave_registry.heartbeat(name)
        if entry.nil?
          render json: { error: "Unknown slave — please re-register" }, status: :not_found
        else
          render json: { ok: true }
        end
      end

      def slaves
        render json: { slaves: Profiler.slave_registry.all }
      end
    end
  end
end
