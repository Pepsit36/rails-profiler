# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"
require "profiler/mcp/tools/set_env_var"
require "profiler/mcp/tools/delete_env_var"

# PROFILER_TEST_RUNNER_CHILD tells the test process started by the test runner not to replay the
# overrides: it is not a variable the env tools may set or delete.
RSpec.describe "The test runner child marker in the env tools", type: :request do
  include Rack::Test::Methods

  let(:writing) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost", "HTTP_X_PROFILER_REQUEST" => "1" } }
  let(:tmp_dir) { Dir.mktmpdir }
  let(:marker) { Profiler::EnvOverrideStore::TEST_RUNNER_CHILD_ENV }

  def app
    Rails.application
  end

  around do |example|
    saved = ENV.to_h
    example.run
  ensure
    ENV.replace(saved)
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      config.tmp_path = Pathname.new(tmp_dir)
    end
    Profiler.instance_variable_set(:@env_override_store, nil)
    ENV.delete(marker)
  end

  def expect_untouched
    expect(ENV).not_to have_key(marker)
    expect(ENV).not_to have_key(marker.downcase)
    expect(Profiler.env_override_store.all_overrides).to be_empty
  end

  %w[PROFILER_TEST_RUNNER_CHILD profiler_test_runner_child].each do |name|
    it "refuses to set #{name} through the endpoint" do
      patch "/_profiler/api/env_vars", { key: name, value: "1" }, writing

      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("PROFILER_TEST_RUNNER_CHILD")
      expect_untouched
    end

    it "refuses to delete #{name} through the endpoint" do
      patch "/_profiler/api/env_vars", { key: name, value: "" }, writing

      expect(last_response.status).to eq(422)
      expect_untouched
    end

    it "refuses to set #{name} through the MCP tool set_env_var" do
      result = Profiler::MCP::Tools::SetEnvVar.call("key" => name, "value" => "1")

      expect(result).to be_a(::MCP::Tool::Response)
      expect(result.error?).to be true
      expect(result.content.first[:text]).to include("PROFILER_TEST_RUNNER_CHILD")
      expect_untouched
    end

    it "refuses to delete #{name} through the MCP tool delete_env_var" do
      result = Profiler::MCP::Tools::DeleteEnvVar.call("key" => name)

      expect(result).to be_a(::MCP::Tool::Response)
      expect(result.error?).to be true
      expect_untouched
    end
  end

  it "still sets another variable" do
    patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_OTHER", value: "1" }, writing

    expect(last_response.status).to eq(200)
    expect(ENV["PROFILER_SPEC_OTHER"]).to eq("1")
  end
end
