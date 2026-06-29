# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe Profiler::Middleware::CorsMiddleware do
  include Rack::Test::Methods

  let(:inner_app) { ->(env) { [200, { "Content-Type" => "text/html" }, ["OK"]] } }

  def app
    described_class.new(inner_app)
  end

  describe "OPTIONS preflight on /_profiler/ path" do
    it "returns 200 with CORS headers" do
      options "/_profiler/api/profiles"

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(last_response.headers["Access-Control-Allow-Methods"]).to include("GET")
    end
  end

  describe "regular request on /_profiler/ path" do
    it "adds CORS headers to the response" do
      get "/_profiler/api/profiles"

      expect(last_response.headers["Access-Control-Allow-Origin"]).to eq("*")
      expect(last_response.headers["Access-Control-Expose-Headers"]).to include("X-Profiler-Token")
    end

    it "removes X-Frame-Options header" do
      inner = ->(env) { [200, { "X-Frame-Options" => "DENY", "Content-Type" => "text/html" }, ["hi"]] }
      app = described_class.new(inner)
      env = Rack::MockRequest.env_for("/_profiler/api/profiles")
      status, headers, _body = app.call(env)

      expect(headers).not_to have_key("X-Frame-Options")
    end

    it "sets Content-Security-Policy frame-ancestors" do
      get "/_profiler/api/profiles"

      expect(last_response.headers["Content-Security-Policy"]).to include("frame-ancestors")
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

  describe "request on a non-profiler path" do
    it "passes through without CORS headers" do
      get "/some/other/path"

      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
    end
  end
end
