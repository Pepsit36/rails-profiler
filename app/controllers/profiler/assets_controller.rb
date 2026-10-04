# frozen_string_literal: true

module Profiler
  class AssetsController < ApplicationController
    # The gem's own static JS and CSS: no application data, cached publicly. Every piece of
    # data they display comes from the API, which keeps the authorization check.
    skip_before_action :verify_authenticity_token
    skip_before_action :check_authorization
    skip_before_action :authorize_request

    def toolbar_js
      path = Profiler::Engine.root.join("app", "assets", "builds", "profiler-toolbar.js")
      js = File.read(path)
      expires_in 1.hour, public: true
      render plain: js, content_type: "application/javascript"
    end

    def main_js
      path = Profiler::Engine.root.join("app", "assets", "builds", "profiler.js")
      js = File.read(path)
      expires_in 1.hour, public: true
      render plain: js, content_type: "application/javascript"
    end

    def main_css
      path = Profiler::Engine.root.join("app", "assets", "builds", "profiler.css")
      css = File.read(path)
      expires_in 1.hour, public: true
      render plain: css, content_type: "text/css"
    end
  end
end
