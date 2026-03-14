# frozen_string_literal: true

module Profiler
  class AssetsController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :check_authorization

    def toolbar_js
      path = Profiler::Engine.root.join("app", "assets", "builds", "profiler-toolbar.js")
      js = File.read(path)
      expires_in 1.hour, public: true
      render plain: js, content_type: "application/javascript"
    end
  end
end
