# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

RSpec.describe "MCP HTTP endpoint behind a reverse proxy", type: :request do
  include Rack::Test::Methods

  let(:headers) do
    { "REMOTE_ADDR" => "127.0.0.1", "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json, text/event-stream" }
  end
  let(:initialize_payload) do
    { jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "spec", version: "0" } } }
  end

  def app
    Rails.application
  end

  def mcp_post(host, extra = {})
    post "/_profiler/mcp", initialize_payload.to_json, headers.merge("HTTP_HOST" => host).merge(extra)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.mcp_enabled = true
      config.mcp_transport = :http
      # The proxy forwards from its own address: the request is let in by authorization_mode,
      # what is checked here is the Host header.
      config.authorization_mode = :allow_all
    end
    Rails.application.reload_routes!
  end

  after do
    Rails.application.config.hosts.clear
    Profiler::MCP::Server.instance_variable_set(:@instance, nil)
  end

  context "with the defaults" do
    it "accepts loopback hosts, with or without a port" do
      %w[localhost 127.0.0.1:3000 [::1]:3000 LOCALHOST:3000].each do |host|
        mcp_post(host)
        expect(last_response.status).to eq(200), "#{host}: #{last_response.status} #{last_response.body}"
      end
    end

    it "refuses any other host, as before" do
      mcp_post("api.travel.local.swile.co")

      expect(last_response.status).to eq(403)
      expect(last_response.body).to include("Host api.travel.local.swile.co is not allowed")
    end
  end

  context "with config.mcp_allowed_hosts" do
    before do
      Profiler.configuration.mcp_allowed_hosts = ["api.travel.local.swile.co", %r{\Atravel-api[a-z0-9-]*\z}]
    end

    it "accepts a listed host name, whatever its case and port" do
      %w[api.travel.local.swile.co API.Travel.Local.Swile.co:443].each do |host|
        mcp_post(host)
        expect(last_response.status).to eq(200), "#{host}: #{last_response.status}"
      end
    end

    it "accepts a host the anchored Regexp matches as a whole" do
      %w[travel-api travel-api-dev:3000 travel-api-feature-42].each do |host|
        mcp_post(host)
        expect(last_response.status).to eq(200), "#{host}: #{last_response.status}"
      end
    end

    it "refuses every other host" do
      %w[evil.example travel-api.evil.example xtravel-api api.travel.local.swile.co.evil.example].each do |host|
        mcp_post(host)
        expect(last_response.status).to eq(403), "#{host}: #{last_response.status}"
      end
    end

    it "still refuses a foreign Origin on an allowed host" do
      mcp_post("api.travel.local.swile.co", "HTTP_ORIGIN" => "https://evil.example")

      expect(last_response.status).to eq(403)
      expect(last_response.body).to include("Origin https://evil.example is not allowed")
    end

    it "accepts the browser's own Origin when TLS ends at the proxy" do
      mcp_post("api.travel.local.swile.co", "HTTP_ORIGIN" => "https://api.travel.local.swile.co")

      expect(last_response.status).to eq(200)
    end
  end

  context "with Rails config.hosts" do
    it "accepts the hosts the application lists, with nothing else to set" do
      Rails.application.config.hosts << "api.travel.local.swile.co" << /\Atravel-api[a-z0-9-]*\z/

      mcp_post("api.travel.local.swile.co")
      expect(last_response.status).to eq(200)
      mcp_post("travel-api-dev")
      expect(last_response.status).to eq(200)
      mcp_post("evil.example")
      expect(last_response.status).to eq(403)
    end

    it "trusts nothing from an empty config.hosts, which turns Rails' check off" do
      Rails.application.config.hosts.clear

      mcp_post("evil.example")
      expect(last_response.status).to eq(403)
    end
  end
end

RSpec.describe Profiler::Configuration, "#mcp_allowed_hosts=" do
  subject(:config) { described_class.new }

  it "defaults to an empty list" do
    expect(config.mcp_allowed_hosts).to eq([])
  end

  it "refuses an unanchored Regexp" do
    [/travel-api/, /\Atravel-api/, /travel-api\z/, /^travel-api$/].each do |pattern|
      expect { config.mcp_allowed_hosts = [pattern] }
        .to raise_error(ArgumentError, /must start with \\A and end with \\z/)
    end
  end

  it "refuses a wildcard or a blank String, and anything else than a String or a Regexp" do
    ["*", "*.swile.co", " ", :any, nil].each do |entry|
      expect { config.mcp_allowed_hosts = [entry] }.to raise_error(ArgumentError)
    end
  end
end
