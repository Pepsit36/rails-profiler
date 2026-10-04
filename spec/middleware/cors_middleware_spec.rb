# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe Profiler::Middleware::CorsMiddleware do
  include Rack::Test::Methods

  let(:inner_app) { ->(env) { [200, { "Content-Type" => "text/html" }, ["OK"]] } }

  def app
    described_class.new(inner_app)
  end

  context "with the default configuration" do
    it "does not answer a preflight itself" do
      options "/_profiler/api/profiles", {}, "HTTP_ORIGIN" => "https://evil.example"

      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
      expect(last_response.headers).not_to have_key("Access-Control-Allow-Methods")
    end

    it "adds no CORS header" do
      get "/_profiler/api/profiles", {}, "HTTP_ORIGIN" => "https://evil.example"

      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
      expect(last_response.headers).not_to have_key("Access-Control-Expose-Headers")
    end

    it "only lets the profiler itself, the extension and DevTools frame it" do
      get "/_profiler/api/profiles"

      expect(last_response.headers["Content-Security-Policy"])
        .to eq("frame-ancestors 'self' chrome-extension: devtools:")
    end

    it "replaces X-Frame-Options with SAMEORIGIN, whatever the case of its key" do
      inner = ->(_env) { [200, { "x-frame-options" => "DENY", "Content-Type" => "text/html" }, ["hi"]] }
      env = Rack::MockRequest.env_for("/_profiler/api/profiles")
      _status, headers, _body = described_class.new(inner).call(env)

      frame_keys = headers.keys.select { |key| key.casecmp?("X-Frame-Options") }
      expect(frame_keys.size).to eq(1)
      expect(headers[frame_keys.first]).to eq("SAMEORIGIN")
    end

    it "uses the configured frame_ancestors" do
      Profiler.configuration.frame_ancestors = ["'self'", "http:", "https:"]
      get "/_profiler/api/profiles"

      expect(last_response.headers["Content-Security-Policy"]).to eq("frame-ancestors 'self' http: https:")
    end

    it "forbids every ancestor when frame_ancestors is empty" do
      Profiler.configuration.frame_ancestors = []
      get "/_profiler/api/profiles"

      expect(last_response.headers["Content-Security-Policy"]).to eq("frame-ancestors 'none'")
    end
  end

  context "with extension_cors_enabled and the former wildcard" do
    before do
      Profiler.configuration.extension_cors_enabled = true
      Profiler.configuration.cors_allowed_origins = ["*"]
    end

    it "answers a preflight with CORS headers" do
      options "/_profiler/api/profiles"

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(last_response.headers["Access-Control-Allow-Methods"]).to include("GET")
      expect(last_response.headers["Access-Control-Allow-Headers"]).to include("X-Profiler-Request")
    end

    it "adds CORS headers to the response" do
      get "/_profiler/api/profiles"

      expect(last_response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(last_response.headers["Access-Control-Expose-Headers"]).to include("X-Profiler-Token")
    end

    it "never answers * to a request carrying a cookie" do
      get "/_profiler/api/profiles", {}, "HTTP_COOKIE" => "_session=abc", "HTTP_ORIGIN" => "https://evil.example"

      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
    end

    it "never answers * to a request carrying an Authorization header" do
      get "/_profiler/api/profiles", {}, "HTTP_AUTHORIZATION" => "Basic Zm9vOmJhcg=="

      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
    end

    it "never allows credentials" do
      get "/_profiler/api/profiles", {}, "HTTP_ORIGIN" => "https://evil.example"

      expect(last_response.headers).not_to have_key("Access-Control-Allow-Credentials")
    end

    context "when downstream returns a frozen headers hash" do
      let(:frozen_headers) { { "Content-Type" => "text/event-stream", "Cache-Control" => "no-cache" }.freeze }
      let(:inner_app) { ->(_env) { [200, frozen_headers, ["data: hello\n\n"]] } }

      it "does not raise and adds CORS/CSP headers without mutating the original hash" do
        original_snapshot = frozen_headers.dup

        env = Rack::MockRequest.env_for("/_profiler/mcp")
        status, headers, _body = app.call(env)

        expect(status).to eq(200)
        expect(headers["Access-Control-Allow-Origin"]).to eq("*")
        expect(headers["Content-Security-Policy"]).to include("frame-ancestors")
        expect(frozen_headers).to eq(original_snapshot)
        expect(frozen_headers).to be_frozen
      end
    end
  end

  context "with an explicitly allowed origin" do
    before do
      Profiler.configuration.extension_cors_enabled = true
      Profiler.configuration.cors_allowed_origins = ["https://myapp.dev"]
    end

    it "reflects that origin and varies on it" do
      get "/_profiler/api/profiles", {}, "HTTP_ORIGIN" => "https://myapp.dev"

      expect(last_response.headers["Access-Control-Allow-Origin"]).to eq("https://myapp.dev")
      expect(last_response.headers["Vary"]).to eq("Origin")
    end

    it "does not answer another origin" do
      get "/_profiler/api/profiles", {}, "HTTP_ORIGIN" => "https://evil.example"

      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
    end
  end

  describe "the profiler root without a trailing slash" do
    it "gets the framing headers even when the application sends no X-Frame-Options" do
      env = Rack::MockRequest.env_for("/_profiler")
      _status, headers, _body = app.call(env)

      expect(headers["Content-Security-Policy"]).to eq("frame-ancestors 'self' chrome-extension: devtools:")
      expect(headers["X-Frame-Options"]).to eq("SAMEORIGIN")
    end

    it "does not take a lookalike path for the profiler" do
      env = Rack::MockRequest.env_for("/_profilerfoo")
      _status, headers, _body = app.call(env)

      expect(headers).not_to have_key("Content-Security-Policy")
    end
  end

  describe "request on a non-profiler path" do
    it "passes through without CORS or framing headers" do
      Profiler.configuration.extension_cors_enabled = true
      Profiler.configuration.cors_allowed_origins = ["*"]
      get "/some/other/path"

      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
      expect(last_response.headers).not_to have_key("Content-Security-Policy")
    end
  end
end
