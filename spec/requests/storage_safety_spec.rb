# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"

# SEC-13 and BUG-09 through the real controller stack.
RSpec.describe "Storage safety through the profiler API", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:writing) { local.merge("HTTP_X_PROFILER_REQUEST" => "1") }

  def app
    Rails.application
  end

  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  ensure
    ENV.delete("PROFILER_SPEC_STORAGE")
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      config.tmp_path = Pathname.new(File.join(@root, "profiler"))
    end
  end

  describe "a traversing profile token" do
    let(:victim) { File.join(@root, "victim.json") }
    let(:victim_json) { JSON.generate("token" => "x", "path" => "/secret") }

    before do
      Profiler.instance_variable_set(:@storage, Profiler::Storage::FileStore.new(path: File.join(@root, "store")))
      File.write(victim, victim_json)
    end

    it "is not found by GET" do
      get "/_profiler/api/profiles/%2e%2e%2fvictim", {}, local
      expect(last_response.status).to eq(404)
    end

    it "is not found by DELETE, and the file outside the store stays" do
      delete "/_profiler/api/profiles/%2e%2e%2fvictim", {}, writing
      expect(last_response.status).to eq(404)
      expect(File.exist?(victim)).to be true
    end

    it "is not found by the AJAX link, and the file outside the store is not overwritten" do
      post "/_profiler/api/ajax/link", { "parent_token" => SecureRandom.hex(16), "child_token" => "../victim" }, writing
      expect(last_response.status).to eq(404)
      expect(File.read(victim)).to eq(victim_json)
    end

    it "is refused as a parent by the AJAX link" do
      child = build_profile
      Profiler.storage.save(child.token, child)

      post "/_profiler/api/ajax/link", { "parent_token" => "../victim", "child_token" => child.token }, writing
      expect(last_response.status).to eq(400)
      expect(Profiler.storage.load(child.token).parent_token).to be_nil
    end
  end

  describe "env overrides that cannot be written" do
    before do
      File.write(File.join(@root, "blocker"), "")
      Profiler.configuration.tmp_path = File.join(@root, "blocker", "profiler")
    end

    it "answers an error and leaves ENV alone" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_STORAGE", value: "1" }, writing

      expect(last_response.status).to eq(500)
      expect(JSON.parse(last_response.body)["error"]).to include("PROFILER_SPEC_STORAGE was left unchanged")
      expect(ENV.key?("PROFILER_SPEC_STORAGE")).to be false
    end
  end
end
