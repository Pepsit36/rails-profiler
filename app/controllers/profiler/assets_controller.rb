# frozen_string_literal: true

module Profiler
  class AssetsController < ApplicationController
    # The gem's own static JS and CSS: no application data, cached publicly. Every piece of
    # data they display comes from the API, which keeps the authorization check.
    skip_before_action :verify_authenticity_token
    skip_before_action :check_authorization
    skip_before_action :authorize_request

    BUILD_MISSING = "Profiler assets are not built (%s is missing). Run `yarn build:full` in the profiler gem."

    def toolbar_js
      serve("profiler-toolbar.js", "application/javascript")
    end

    def main_js
      serve("profiler.js", "application/javascript")
    end

    def main_css
      serve("profiler.css", "text/css")
    end

    def icon
      expires_in 1.day, public: true
      send_file Profiler::Engine.root.join("app", "assets", "images", "icon.png"), type: "image/png", disposition: "inline"
    end

    private

    def serve(name, content_type)
      body = File.read(Profiler::Engine.root.join("app", "assets", "builds", name))
      expires_in 1.hour, public: true
      render plain: body, content_type: content_type
    rescue Errno::ENOENT
      render plain: format(BUILD_MISSING, name), status: :not_found
    end
  end
end
