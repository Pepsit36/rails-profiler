# frozen_string_literal: true

require "rails/engine"

module Profiler
  class Engine < ::Rails::Engine
    isolate_namespace Profiler

    config.profiler = ActiveSupport::OrderedOptions.new

    initializer "profiler.helpers" do
      ActiveSupport.on_load(:action_controller) do
        helper Profiler::Engine.helpers
      end
    end
  end
end
