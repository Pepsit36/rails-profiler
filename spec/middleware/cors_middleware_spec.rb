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
  end

  describe "request on a non-profiler path" do
    it "passes through without CORS headers" do
      get "/some/other/path"

      expect(last_response.status).to eq(200)
      expect(last_response.headers).not_to have_key("Access-Control-Allow-Origin")
    end
  end
end
