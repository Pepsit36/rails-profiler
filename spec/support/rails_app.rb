# frozen_string_literal: true

# A minimal Rails application mounting the engine, for request specs that need the
# real controller stack (filters, forgery protection, middleware). Required by the
# request specs only: the unit specs do not depend on it.
ENV["RAILS_ENV"] ||= "test"

require "fileutils"
require "logger"
require "tmpdir"
require "rails"
require "action_controller/railtie"
require "profiler/railtie"
require "profiler/engine"

module ProfilerSpecApp
  class Application < Rails::Application
    # Not the gem root: its config/routes.rb holds the engine routes.
    config.root = Dir.mktmpdir("profiler-spec-app").tap { |dir| at_exit { FileUtils.remove_entry(dir) } }
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "a" * 64
    config.hosts.clear
    config.action_dispatch.show_exceptions = :none
    config.action_controller.allow_forgery_protection = true

    routes.append do
      mount Profiler::Engine, at: "/_profiler"
      get "/hello", to: ->(_env) { [200, { "content-type" => "text/html" }, ["<html><body>hi</body></html>"]] }
    end
  end
end

ProfilerSpecApp::Application.initialize! unless ProfilerSpecApp::Application.initialized?
