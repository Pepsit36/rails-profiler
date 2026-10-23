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

  # rack-test sends REMOTE_ADDR 127.0.0.1: a browser on this machine, as :allow_local expects.
  def default_host
    "localhost"
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

  describe "when the authorize_with block raises" do
    before do
      Profiler.configure do |c|
        c.authorization_mode = :allow_authorized
        c.authorize_with { |_request| raise "secret internal detail" }
      end
    end

    it "treats it as a denial: the application answers and nothing leaks" do
      expect(Profiler).to receive(:log_error).with(/authorize_with/, instance_of(RuntimeError))
      get "/users"
      expect(last_response.status).to eq(200)
      expect(last_response.body).not_to include("secret internal detail")
      expect(last_response.headers).not_to have_key("X-Profiler-Token")
    end
  end

  describe "default skip_paths" do
    before { Profiler.configure { |c| c.skip_paths = Profiler::Configuration.new.skip_paths } }

    %w[/assets/application.css /cable /cable/x /_profiler/x /favicon.ico /manifest.json /x/manifest.json /packs/manifest.json /.well-known/a].each do |path|
      it "does not profile #{path}" do
        get path
        expect(last_response.headers).not_to have_key("X-Profiler-Token")
      end
    end

    it "profiles a path that merely ends like a manifest" do
      get "/x/manifest.json.html"
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    end

    it "profiles a path that merely contains a skipped word" do
      get "/users/favicon.ico.html"
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    end
  end

  describe "when skip_paths lists a String" do
    before do
      Profiler.configure { |c| c.skip_paths = ["/health", %r{\A/assets/}] }
    end

    it "skips the path equal to it" do
      get "/health"
      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("X-Profiler-Token")
    end

    it "profiles any other path, one that only starts with it included" do
      get "/health/details"
      expect(last_response.status).to eq(200)
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    end

    it "still matches the Regexps next to it" do
      get "/assets/application.css"
      expect(last_response.headers).not_to have_key("X-Profiler-Token")
    end
  end

  describe "when skip_paths is set to a single pattern" do
    it "reads a String as a list of one" do
      Profiler.configure { |c| c.skip_paths = "/health" }

      get "/health"
      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("X-Profiler-Token")
      get "/users"
      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    end

    it "reads a Regexp as a list of one" do
      Profiler.configure { |c| c.skip_paths = %r{\A/assets/} }

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

  describe "toolbar injection guards" do
    describe "when response has Content-Disposition: attachment" do
      let(:inner_app) do
        ->(env) { [200, { "Content-Type" => "text/html", "Content-Disposition" => "attachment; filename=file.html" }, ["<html><body>download</body></html>"]] }
      end

      it "does not inject toolbar" do
        get "/download"
        expect(last_response.body).not_to include("profiler-toolbar")
      end

      it "still sets the token header (the profile is saved even though the toolbar is not injected)" do
        get "/download"
        expect(last_response.headers).to have_key("X-Profiler-Token")
      end

      it "keeps the response body unchanged" do
        get "/download"
        expect(last_response.body).to eq("<html><body>download</body></html>")
      end
    end

    describe "when response has Content-Encoding" do
      let(:inner_app) do
        ->(env) { [200, { "Content-Type" => "text/html", "Content-Encoding" => "gzip" }, ["<html><body>compressed</body></html>"]] }
      end

      it "does not inject toolbar" do
        get "/compressed"
        expect(last_response.body).not_to include("profiler-toolbar")
      end

      it "still sets the token header (the profile is saved even though the toolbar is not injected)" do
        get "/compressed"
        expect(last_response.headers).to have_key("X-Profiler-Token")
      end
    end

    describe "when response is normal HTML without guards" do
      it "injects toolbar (regression test)" do
        get "/users"
        expect(last_response.body).to include("profiler-toolbar")
      end

      it "sets token header (regression test)" do
        get "/users"
        expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
      end
    end

    describe "when toolbar is injected, ETag and Last-Modified are removed" do
      let(:inner_app) do
        ->(env) do
          headers = {
            "Content-Type" => "text/html",
            "ETag" => '"abc123"',
            "Last-Modified" => "Mon, 23 Oct 2026 10:00:00 GMT"
          }
          [200, headers, ["<html><body>page</body></html>"]]
        end
      end

      it "removes ETag header when toolbar is injected" do
        get "/users"
        expect(last_response.headers).not_to have_key("ETag")
        expect(last_response.headers).not_to have_key("etag")
      end

      it "removes Last-Modified header when toolbar is injected" do
        get "/users"
        expect(last_response.headers).not_to have_key("Last-Modified")
        expect(last_response.headers).not_to have_key("last-modified")
      end

      it "still injects toolbar" do
        get "/users"
        expect(last_response.body).to include("profiler-toolbar")
      end
    end
  end
end
