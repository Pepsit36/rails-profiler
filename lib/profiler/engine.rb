# frozen_string_literal: true

require "rails/engine"

module Profiler
  class Engine < ::Rails::Engine
    isolate_namespace Profiler

    config.profiler = ActiveSupport::OrderedOptions.new

    initializer "profiler.helpers" do
      # The hook runs for ActionController::API as well, which has no view helpers.
      ActiveSupport.on_load(:action_controller) do
        helper Profiler::Engine.helpers if respond_to?(:helper)
      end
    end
  end
end
