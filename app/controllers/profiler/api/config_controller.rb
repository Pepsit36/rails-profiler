# frozen_string_literal: true

module Profiler
  module Api
    # Read-only: the settings the file:line links need, for the dashboard and for the browser
    # extension, which falls back on them when it has none of its own.
    class ConfigController < ApplicationController
      def show
        config = Profiler.configuration
        render json: {
          editor_url_scheme: config.editor_link_scheme,
          editor_path_map: config.editor_path_map
        }
      end
    end
  end
end
