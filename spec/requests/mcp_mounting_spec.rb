# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require_relative "../support/rails_app"

RSpec.describe "MCP HTTP endpoint", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:remote) { { "REMOTE_ADDR" => "10.0.0.5", "HTTP_HOST" => "localhost" } }
  let(:mcp_headers) do
    { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json, text/event-stream" }
  end

  def app
    Rails.application
  end

  # The spec application raises routing errors; render them as an application does, so that
  # a route that is not there answers 404.
  def with_rendered_errors
    env_config = Rails.application.env_config
    previous = env_config["action_dispatch.show_exceptions"]
    env_config["action_dispatch.show_exceptions"] = :all
    yield
  ensure
    env_config["action_dispatch.show_exceptions"] = previous
  end

  def default_host
    "localhost"
  end

  def mcp_post(payload, env)
    post "/_profiler/mcp", payload.to_json, env
  end

  # The JSON-RPC answer, whether the transport replied with plain JSON or with one SSE event.
  def rpc_result
    body = last_response.body
    data = body.lines.find { |line| line.start_with?("data:") }
    JSON.parse(data ? data.delete_prefix("data:") : body)
  end

  def initialize_payload
    {
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "spec", version: "0" } }
    }
  end

  # Runs the MCP handshake and returns the session id the transport handed out.
  def handshake(env)
    mcp_post(initialize_payload, env)
    expect(last_response.status).to eq(200)
    session = last_response.headers["Mcp-Session-Id"] || last_response.headers["mcp-session-id"]
    mcp_post({ jsonrpc: "2.0", method: "notifications/initialized" }, env.merge("HTTP_MCP_SESSION_ID" => session))
    session
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler::LocalRequest.reset_warning!
  end

  context "when mcp_enabled is false (the default)" do
    around { |example| with_rendered_errors { example.run } }

    it "does not route /_profiler/mcp" do
      mcp_post(initialize_payload, local.merge(mcp_headers))
      expect(last_response.status).to eq(404)
    end
  end

  context "when mcp_enabled is true with the stdio transport" do
    before { Profiler.configuration.mcp_enabled = true }
    around { |example| with_rendered_errors { example.run } }

    it "does not route /_profiler/mcp" do
      mcp_post(initialize_payload, local.merge(mcp_headers))
      expect(last_response.status).to eq(404)
    end
  end

  context "when mcp_enabled is true with the HTTP transport" do
    before do
      Profiler.configure do |config|
        config.mcp_enabled = true
        config.mcp_transport = :http
      end
    end

    it "lists the tools to an authorized client" do
      session = handshake(local.merge(mcp_headers))
      mcp_post({ jsonrpc: "2.0", id: 2, method: "tools/list" }, local.merge(mcp_headers).merge("HTTP_MCP_SESSION_ID" => session))

      expect(last_response.status).to eq(200)
      names = rpc_result.dig("result", "tools").map { |tool| tool["name"] }
      expect(names).to include("query_profiles", "set_env_var", "clear_profiles")
    end

    it "refuses an unauthorized client before the MCP handshake" do
      mcp_post(initialize_payload, remote.merge(mcp_headers))

      expect(last_response.status).to eq(403)
      expect(last_response.headers["Mcp-Session-Id"]).to be_nil
    end

    it "refuses a client the authorize_with block rejects" do
      Profiler.configure do |config|
        config.authorization_mode = :allow_authorized
        config.authorize_with { |_request| false }
      end

      mcp_post(initialize_payload, local.merge(mcp_headers))
      expect(last_response.status).to eq(403)
    end

    it "refuses a POST that a cross-site form could send (no JSON Content-Type)" do
      mcp_post(initialize_payload, local.merge("CONTENT_TYPE" => "text/plain", "HTTP_ACCEPT" => mcp_headers["HTTP_ACCEPT"]))

      expect(last_response.status).to eq(403)
      expect(last_response.body).to match(/Content-Type/)
    end

    it "refuses a POST from a foreign browser origin" do
      mcp_post(initialize_payload, local.merge(mcp_headers).merge("HTTP_ORIGIN" => "https://evil.example"))
      expect(last_response.status).to eq(403)
    end

    it "accepts a POST from the profiler's own origin" do
      mcp_post(initialize_payload, local.merge(mcp_headers).merge("HTTP_ORIGIN" => "http://localhost"))
      expect(last_response.status).to eq(200)
    end

    it "refuses every request when the profiler is disabled" do
      Profiler.configuration.enabled = false

      mcp_post(initialize_payload, local.merge(mcp_headers))
      expect(last_response.status).to eq(403)
    end

    it "lets api_forgery_protection = false skip the Content-Type check" do
      Profiler.configuration.api_forgery_protection = false

      mcp_post(initialize_payload, local.merge("CONTENT_TYPE" => "text/plain", "HTTP_ACCEPT" => mcp_headers["HTTP_ACCEPT"]))
      expect(last_response.status).not_to eq(403)
    end
  end

  # A remote client calling a tool that writes ENV, end to end: handshake, then tools/call
  # set_env_var. Each step is sent whatever the previous one answered, as an attacker would.
  describe "tools/call set_env_var, end to end" do
    let(:key) { "PROFILER_SPEC_MCP_PROBE" }
    let(:tmp) { Pathname(Dir.mktmpdir("profiler-mcp-spec")) }

    before do
      ENV.delete(key)
      Profiler.instance_variable_set(:@env_override_store, nil)
      Profiler.configure do |config|
        config.mcp_enabled = true
        config.mcp_transport = :http
        config.tmp_path = tmp
      end
    end

    after do
      ENV.delete(key)
      Profiler.instance_variable_set(:@env_override_store, nil)
      FileUtils.remove_entry(tmp)
    end

    # The SSE answer is a lazy body: the tool only runs while it is read, so each answer is
    # read in full, as a client would.
    def call_set_env_var(env)
      mcp_post(initialize_payload, env)
      last_response.body
      session = last_response.headers["Mcp-Session-Id"] || last_response.headers["mcp-session-id"]
      session_env = session ? env.merge("HTTP_MCP_SESSION_ID" => session) : env
      mcp_post({ jsonrpc: "2.0", method: "notifications/initialized" }, session_env)
      last_response.body
      mcp_post({ jsonrpc: "2.0", id: 2, method: "tools/call",
                 params: { name: "set_env_var", arguments: { key: key, value: "pwned" } } }, session_env)
      last_response.body
      last_response.status
    end

    it "(a) is refused while the profiler is disabled, and ENV is unchanged" do
      Profiler.configuration.enabled = false

      expect(call_set_env_var(local.merge(mcp_headers))).to eq(403)
      expect(ENV[key]).to be_nil
    end

    it "(b) is refused from a remote address that authorization_mode does not admit" do
      remote_client = { "REMOTE_ADDR" => "203.0.113.9", "HTTP_HOST" => "localhost" }

      expect(call_set_env_var(remote_client.merge(mcp_headers))).to eq(403)
      expect(ENV[key]).to be_nil
    end

    it "(c) is accepted from this machine with Content-Type: application/json" do
      expect(call_set_env_var(local.merge(mcp_headers))).to eq(200)
      expect(ENV[key]).to eq("pwned")
    end
  end
end
