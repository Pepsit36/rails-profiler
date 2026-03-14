# frozen_string_literal: true

module Profiler
  class ApplicationController < ActionController::Base
    protect_from_forgery with: :exception

    layout "profiler/application"

    before_action :check_authorization

    private

    def check_authorization
      unless Profiler.configuration.enabled
        render plain: "Profiler is disabled", status: :forbidden
      end
    end
  end
end
