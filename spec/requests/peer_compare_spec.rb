# frozen_string_literal: true

require "spec_helper"
require "webmock"
require "webmock/rspec/matchers"
require_relative "../support/rails_app"

RSpec.describe "Comparing profiles across peers", type: :request do
  include Rack::Test::Methods
  include WebMock::API
  include WebMock::Matchers

  let(:peer_token) { "peer-token-0123456789abcdefghijklmnopqr" }
  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:remote) { { "REMOTE_ADDR" => "10.0.0.5", "HTTP_HOST" => "app.internal" } }
  let(:peer_header) { { "HTTP_X_PROFILER_PEER_TOKEN" => peer_token } }

  def app
    Rails.application
  end

  def default_host
    "localhost"
  end

  def json
    JSON.parse(last_response.body)
  end

  before do
    WebMock.enable!
    WebMock.disable_net_connect!
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      config.peers = [{ name: "staging", url: "https://staging.example.com" }]
      config.peer_token = peer_token
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler::LocalRequest.reset_warning!
  end

  after do
    WebMock.reset!
    WebMock.allow_net_connect!
    WebMock.disable!
  end

  def store(profile)
    Profiler.storage.save(profile.token, profile)
    profile
  end

  describe "GET /_profiler/api/compare" do
    it "compares two local profiles" do
      a = store(build_profile)
      b = store(build_profile)
      get "/_profiler/api/compare", { a: a.token, b: b.token }, local
      expect(last_response.status).to eq(200)
      expect(json["sql"].keys).to eq(%w[new gone slower])
    end

    it "refuses a node outside config.peers, with no outgoing call" do
      a = store(build_profile)
      get "/_profiler/api/compare", { a: a.token, b: "b" * 32, node_b: "prod" }, local
      expect(last_response.status).to eq(502)
      expect(json["errors"].first).to match(/Unknown node "prod"/)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "never uses a URL given in the request as a call target" do
      a = store(build_profile)
      get "/_profiler/api/compare",
          { a: a.token, b: "b" * 32, node_b: "https://evil.example.com", url: "https://evil.example.com",
            peer_url: "https://evil.example.com", base_url: "https://evil.example.com" }, local
      expect(last_response.status).to eq(502)
      expect(a_request(:any, /evil\.example\.com/)).not_to have_been_made
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "fails clearly when peers are configured without a peer_token" do
      Profiler.configuration.peer_token = nil
      a = store(build_profile)
      get "/_profiler/api/compare", { a: a.token, b: "b" * 32, node_b: "staging" }, local
      expect(last_response.status).to eq(502)
      expect(json["errors"].first).to match(/No config.peer_token/)
      expect(a_request(:any, /.*/)).not_to have_been_made
    end

    it "reads profile B from the peer, with the token header" do
      a = store(build_profile(path: "/local"))
      remote_profile = build_profile(path: "/remote")
      stub = stub_request(:get, "https://staging.example.com/_profiler/api/profiles/#{remote_profile.token}")
             .with(headers: { "X-Profiler-Peer-Token" => peer_token })
             .to_return(status: 200, body: remote_profile.to_h.to_json)

      get "/_profiler/api/compare", { a: a.token, b: remote_profile.token, node_b: "staging" }, local
      expect(last_response.status).to eq(200)
      expect(json["profile_b"]).to include("node" => "staging", "path" => "/remote")
      expect(stub).to have_been_requested
    end

    it "reports an unreachable peer" do
      a = store(build_profile)
      stub_request(:get, %r{staging.example.com}).to_timeout
      get "/_profiler/api/compare", { a: a.token, b: "b" * 32, node_b: "staging" }, local
      expect(last_response.status).to eq(502)
      expect(json["errors"].first).to match(/unreachable/)
    end

    it "lists the nodes: local, then config.peers" do
      get "/_profiler/api/compare/nodes", {}, local
      expect(json["nodes"]).to eq(%w[local staging])
    end
  end

  describe "serving a profile to a peer" do
    it "lets a remote peer with the right token read one profile" do
      profile = store(build_profile)
      get "/_profiler/api/profiles/#{profile.token}", {}, remote.merge(peer_header)
      expect(last_response.status).to eq(200)
      expect(json["token"]).to eq(profile.token)
    end

    it "refuses a remote client with a wrong token" do
      profile = store(build_profile)
      get "/_profiler/api/profiles/#{profile.token}", {}, remote.merge("HTTP_X_PROFILER_PEER_TOKEN" => "x" * 40)
      expect(last_response.status).to eq(403)
    end

    it "refuses everything when no peer_token is configured, even with an empty header" do
      Profiler.configuration.peer_token = nil
      profile = store(build_profile)
      get "/_profiler/api/profiles/#{profile.token}", {}, remote.merge("HTTP_X_PROFILER_PEER_TOKEN" => "")
      expect(last_response.status).to eq(403)
    end

    it "does not open the other endpoints to the peer token" do
      get "/_profiler/api/profiles", {}, remote.merge(peer_header)
      expect(last_response.status).to eq(403)
      profile = store(build_profile)
      delete "/_profiler/api/profiles/#{profile.token}", {}, remote.merge(peer_header).merge("HTTP_X_PROFILER_REQUEST" => "1")
      expect(last_response.status).to eq(403)
      expect(Profiler.storage.load(profile.token)).not_to be_nil
    end
  end
end
