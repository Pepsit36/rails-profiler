# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe Profiler::Middleware::ProfilerMiddleware do
  include Rack::Test::Methods

  let(:inner_app) do
    ->(env) { [200, { "Content-Type" => "text/html" }, ["<html><body>hello</body></html>"]] }
  end

  def app
    described_class.new(inner_app)
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = []
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  describe "when profiler is disabled" do
    before do
      Profiler.configure { |c| c.enabled = false }
    end

    it "passes the request through unchanged" do
      get "/users"
      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("X-Profiler-Token")
    end
  end

  describe "when path matches skip_paths" do
    before do
      Profiler.configure { |c| c.skip_paths = [%r{^/assets/}] }
    end

    it "passes through without profiling" do
      get "/assets/application.css"
      expect(last_response.headers).not_to have_key("X-Profiler-Token")
    end
  end

  describe "when profiler is enabled on an HTML response" do
    it "adds X-Profiler-Token header" do
      get "/users"
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    end

    it "injects toolbar into the body" do
      get "/users"
      expect(last_response.body).to include("profiler-toolbar")
    end

    it "saves the profile to storage" do
      get "/users"
      token = last_response.headers["X-Profiler-Token"]
      profile = Profiler.storage.load(token)
      expect(profile).not_to be_nil
      expect(profile.path).to eq("/users")
    end
  end

  describe "when profiler is enabled on a non-HTML response" do
    let(:inner_app) do
      ->(env) { [200, { "Content-Type" => "application/json" }, ['{"ok":true}']] }
    end

    it "adds X-Profiler-Token header" do
      get "/api/users"
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    end

    it "does not inject toolbar" do
      get "/api/users"
      expect(last_response.body).not_to include("profiler-toolbar")
    end
  end

  describe "when a collector raises an exception" do
    let(:bad_collector_class) do
      klass = Class.new(Profiler::Collectors::BaseCollector) do
        def collect
          raise "boom"
        end
      end
      klass
    end

    before do
      Profiler.configure { |c| c.collectors = [bad_collector_class] }
    end

    it "still returns the app response" do
      get "/users"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    end
  end

  describe "when the middleware itself fails catastrophically" do
    before do
      allow_any_instance_of(described_class).to receive(:create_collectors).and_raise("catastrophe")
    end

    it "falls back to @app.call" do
      get "/users"
      expect(last_response.status).to eq(200)
      # No profiler token since it fell back
      expect(last_response.headers).not_to have_key("X-Profiler-Token")
    end
  end
end
