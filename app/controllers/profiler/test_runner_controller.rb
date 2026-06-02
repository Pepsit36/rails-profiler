# frozen_string_literal: true

module Profiler
  class TestRunnerController < ApplicationController
    layout "profiler/application"

    def index
      redirect_to profiler.root_path(section: "runner"), allow_other_host: false
    end
  end
end
