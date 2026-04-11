# frozen_string_literal: true

module Profiler
  module Api
    class FunctionProfilingController < ApplicationController
      skip_before_action :verify_authenticity_token

      def show
        render json: {
          enabled:    Profiler.function_profiling_enabled,
          max_frames: Profiler.function_profiling_max_frames,
          mode:       Profiler.function_profiling_mode,
          clock:      Profiler.function_profiling_clock
        }
      end

      def update
        if params.key?(:enabled)
          Profiler.function_profiling_enabled = params[:enabled] == true || params[:enabled] == "true"
        end

        if params.key?(:max_frames)
          max = params[:max_frames].to_i
          Profiler.function_profiling_max_frames = max.positive? ? max : Profiler.function_profiling_max_frames
        end

        if params.key?(:mode) && %w[full lite minimal].include?(params[:mode])
          Profiler.function_profiling_mode = params[:mode]
        end

        if params.key?(:clock) && %w[wall cpu object].include?(params[:clock])
          Profiler.function_profiling_clock = params[:clock]
        end

        render json: {
          enabled:    Profiler.function_profiling_enabled,
          max_frames: Profiler.function_profiling_max_frames,
          mode:       Profiler.function_profiling_mode,
          clock:      Profiler.function_profiling_clock
        }
      end
    end
  end
end
