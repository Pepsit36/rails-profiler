# frozen_string_literal: true

module Profiler
  module Api
    class ConsoleController < ApplicationController
      def index
        render_profile_page(type: "console")
      end

      def show
        profile = Profiler.storage.load(params[:id])

        unless profile && profile.profile_type == "console"
          return render json: { error: "Console profile not found" }, status: :not_found
        end

        render json: profile.to_h
      end

      def destroy
        profile = Profiler.storage.load(params[:id])
        return render json: { error: "Console profile not found" }, status: :not_found unless profile&.profile_type == "console"

        Profiler.storage.delete(params[:id])
        head :no_content
      end

      def clear
        Profiler.storage.clear(type: "console")
        head :no_content
      end
    end
  end
end
