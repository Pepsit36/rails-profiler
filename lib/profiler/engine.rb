# frozen_string_literal: true

require "rails/engine"

module Profiler
  class Engine < ::Rails::Engine
    isolate_namespace Profiler

    config.profiler = ActiveSupport::OrderedOptions.new

    initializer "profiler.assets" do |app|
      if app.config.respond_to?(:assets)
        app.config.assets.paths << root.join("app/assets/builds")
        app.config.assets.paths << root.join("app/assets/typescript")
        app.config.assets.paths << root.join("app/assets/stylesheets")
        app.config.assets.precompile += %w[profiler.js profiler.css profiler-toolbar.js profiler/main.js profiler/main.css]
      end
    end

    initializer "profiler.helpers" do
      ActiveSupport.on_load(:action_controller) do
        helper Profiler::Engine.helpers
      end
    end
  end
end
