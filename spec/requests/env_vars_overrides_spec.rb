# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"

# SEC-08 through the real controller stack: an overrides file shipped with the application,
# whose "original" values come from the machine that wrote it.
RSpec.describe "Env overrides through the profiler API", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:writing) { local.merge("HTTP_X_PROFILER_REQUEST" => "1") }
  let(:tmp_dir) { Dir.mktmpdir }

  def app
    Rails.application
  end

  around do |example|
    saved = ENV.fetch("PROFILER_SPEC_DEPLOYED", nil)
    ENV["PROFILER_SPEC_DEPLOYED"] = "deployed-value"
    example.run
  ensure
    saved.nil? ? ENV.delete("PROFILER_SPEC_DEPLOYED") : ENV["PROFILER_SPEC_DEPLOYED"] = saved
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
    File.write(
      File.join(tmp_dir, "env_overrides.json"),
      JSON.generate("PROFILER_SPEC_DEPLOYED" => { "value" => "dev-override", "original" => "dev-machine-value" })
    )
  end

  context "in production" do
    before { allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production")) }

    it "lets a reset undo the file's original value, typed back in" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_DEPLOYED", value: "dev-machine-value" }, writing
      expect(last_response.status).to eq(200)
      expect(ENV["PROFILER_SPEC_DEPLOYED"]).to eq("dev-machine-value")

      delete "/_profiler/api/env_vars/reset?key=PROFILER_SPEC_DEPLOYED", {}, writing
      expect(last_response.status).to eq(200)
      expect(ENV["PROFILER_SPEC_DEPLOYED"]).to eq("deployed-value")
    end

    it "leaves ENV alone on a reset of a key this process never changed" do
      delete "/_profiler/api/env_vars/reset?key=PROFILER_SPEC_DEPLOYED", {}, writing
      expect(last_response.status).to eq(200)
      expect(ENV["PROFILER_SPEC_DEPLOYED"]).to eq("deployed-value")
    end
  end

  context "where the overrides are allowed" do
    it "treats a value equal to the original as a reset, as before" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_DEPLOYED", value: "dev-machine-value" }, writing
      expect(last_response.status).to eq(200)
      expect(ENV["PROFILER_SPEC_DEPLOYED"]).to eq("dev-machine-value")
      expect(Profiler.env_override_store.all_overrides).not_to have_key("PROFILER_SPEC_DEPLOYED")
    end
  end
end
