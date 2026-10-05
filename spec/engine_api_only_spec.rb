# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# An application whose controllers inherit from ActionController::API (an api_only application,
# or one API controller beside the others) loads the engine without error.
RSpec.describe "Engine in an application that loads ActionController::API" do
  def boot(api_only:)
    script = <<~RUBY
      require "bundler/setup"
      require "logger"
      require "rails"
      require "action_controller/railtie"
      require "profiler"

      class ProbeApp < Rails::Application
        config.root = ENV.fetch("PROBE_ROOT")
        config.eager_load = false
        config.secret_key_base = "x" * 64
        config.logger = Logger.new(nil)
        config.hosts.clear
        config.api_only = #{api_only}
        config.profiler.enabled = true
        config.profiler.storage = :memory
      end
      ProbeApp.initialize!

      class ProbeApiController < ActionController::API; end
      class ProbeBaseController < ActionController::Base; end
      puts "booted"
    RUBY
    Dir.mktmpdir("profiler-api-only") do |root|
      Open3.capture2e({ "PROBE_ROOT" => root, "RAILS_ENV" => "development" }, RbConfig.ruby, "-e", script,
                      chdir: File.expand_path("..", __dir__))
    end
  end

  it "boots an api_only application" do
    output, status = boot(api_only: true)

    expect(output).to include("booted"), output
    expect(status).to be_success
  end

  it "boots an application with API and HTML controllers" do
    output, status = boot(api_only: false)

    expect(output).to include("booted"), output
    expect(status).to be_success
  end
end
