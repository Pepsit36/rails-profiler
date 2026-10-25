# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "sqlite3"
require "tmpdir"
require "fileutils"
require_relative "../support/rails_app"
require "profiler/explain_runner"
require "profiler/mcp/tools/explain_query"
require "profiler/cluster/slave_registry"
require "profiler/cluster/slave_proxy"

# #47 SEC-22: an unexpected error is answered with a generic message; its own message, which
# can carry SQL, an internal path or an internal address, goes to the server log only.
RSpec.describe "Internal error messages", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:writing) { local.merge("HTTP_X_PROFILER_REQUEST" => "1") }
  let(:storage) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
  end

  def stored_profile
    profile = build_profile(collectors_data: { "database" => { "queries" => [{ "sql" => "SELECT 1", "binds" => [] }] } })
    storage.save(profile.token, profile)
    profile
  end

  describe "POST /_profiler/api/explain" do
    let(:internal) { "PG::Error at /srv/app/secret/path.rb SELECT * FROM users" }

    it "answers 500 with a generic message and logs the database's message" do
      token = stored_profile.token
      allow(Profiler::ExplainRunner).to receive(:run).and_raise(RuntimeError, internal)

      log = capture_profiler_log { post "/_profiler/api/explain", { token: token, query_index: 0 }, writing }

      expect(last_response.status).to eq(500)
      expect(json).to eq("error" => "Explain failed")
      expect(last_response.body).not_to include("/srv/app", "SELECT", "PG::Error")
      expect(log).to include("Explain: failed for query 0 of profile #{token.inspect}", "RuntimeError", internal)
    end

    it "answers an ArgumentError from below the runner as an internal error, not a 422" do
      allow(Profiler::ExplainRunner).to receive(:run).and_raise(ArgumentError, internal)

      log = capture_profiler_log { post "/_profiler/api/explain", { token: stored_profile.token, query_index: 0 }, writing }

      expect(last_response.status).to eq(500)
      expect(json).to eq("error" => "Explain failed")
      expect(log).to include(internal)
    end

    it "still answers the runner's own refusals with their reason" do
      post "/_profiler/api/explain", { token: stored_profile.token, query_index: 7 }, writing

      expect(last_response.status).to eq(422)
      expect(json["error"]).to eq("Query index 7 out of range (0..0)")
    end
  end

  describe "the MCP explain_query tool" do
    it "answers a generic message and logs the database's message" do
      token = stored_profile.token
      allow(Profiler::ExplainRunner).to receive(:run).and_raise(RuntimeError, "PG::Error at /srv/app/x.rb SELECT * FROM users")

      text = nil
      log = capture_profiler_log { text = Profiler::MCP::Tools::ExplainQuery.call("token" => token, "query_index" => 0).first[:text] }

      expect(text).to eq("EXPLAIN failed (the application log has the details)")
      expect(log).to include("MCP explain_query: failed for query 0", "PG::Error at /srv/app/x.rb SELECT * FROM users")
    end
  end

  describe "the MCP explain_query tool against an unknown slave" do
    after { Profiler.instance_variable_set(:@slave_registry, nil) }

    it "answers the dedicated message, not the generic one" do
      Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)

      text = Profiler::MCP::Tools::ExplainQuery.call("token" => "abc", "query_index" => 0, "slave" => "ghost").content.first[:text]

      expect(text).to eq("Error: Unknown slave profiler: ghost")
      expect(text).not_to include("EXPLAIN failed")
    end
  end

  describe "POST /_profiler/api/ajax/link" do
    it "answers 500 with a generic message and logs the storage's message" do
      parent = stored_profile
      child = stored_profile
      allow(storage).to receive(:save).and_raise(Errno::EACCES, "/srv/app/internal/file_store.rb")

      log = capture_profiler_log do
        post "/_profiler/api/ajax/link", { parent_token: parent.token, child_token: child.token }, writing
      end

      expect(last_response.status).to eq(500)
      expect(json).to eq("error" => "Could not link the Ajax request")
      expect(last_response.body).not_to include("/srv/app", "Errno", "Permission")
      expect(log).to include("Ajax: could not link the request", "Errno::EACCES", "/srv/app/internal/file_store.rb")
    end
  end

  describe "the slave proxy" do
    before do
      Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
      Profiler.configure do |config|
        config.cluster_master = true
        config.cluster_secret = "s3cret-shared-by-the-cluster-0123456789"
        config.cluster_allowed_slave_urls = ["https://payment.internal"]
      end
      Profiler.slave_registry.register(name: "payment", url: "https://payment.internal")
    end

    after { Profiler.instance_variable_set(:@slave_registry, nil) }

    it "answers 502 with a generic message and logs the network error" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED, "10.0.0.9:3000 /srv/app/x.rb")

      log = capture_profiler_log { get "/_profiler/api/slaves/payment/profiles", {}, local }

      expect(last_response.status).to eq(502)
      expect(json).to eq("error" => "Proxy error")
      expect(last_response.body).not_to include("10.0.0.9", "/srv/app", "ECONNREFUSED")
      expect(log).to include("SlaveProxy: could not forward GET to slave profiler \"payment\"",
                             "Errno::ECONNREFUSED", "10.0.0.9:3000 /srv/app/x.rb")
    end

    it "still answers the profiler's own refusals with their reason" do
      get "/_profiler/api/slaves/unknown/profiles", {}, local

      expect(last_response.status).to eq(502)
      expect(json).to eq("error" => "Unknown slave profiler: unknown")
    end
  end
end
