# frozen_string_literal: true

require "spec_helper"
require "profiler/profile_diff"
require "profiler/mcp/tools/compare_profiles"

RSpec.describe Profiler::MCP::Tools::CompareProfiles do
  before do
    Profiler.configure { |c| c.regression_duration_threshold = 10 }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def call(params)
    described_class.call(params)
  end

  def store(profile)
    Profiler.storage.save(profile.token, profile)
    profile
  end

  describe "missing parameters" do
    it "returns error when token_a is missing" do
      result = call({ "token_b" => "bbb" })
      expect(result.first[:text]).to include("Error")
      expect(result.first[:text]).to include("token_a")
    end

    it "returns error when token_b is missing" do
      result = call({ "token_a" => "aaa" })
      expect(result.first[:text]).to include("Error")
      expect(result.first[:text]).to include("token_b")
    end

    it "returns error when both tokens are missing" do
      result = call({})
      expect(result.first[:text]).to include("Error")
    end
  end

  describe "same token twice" do
    it "returns error" do
      p = store(build_profile)
      result = call({ "token_a" => p.token, "token_b" => p.token })
      expect(result.first[:text]).to include("Cannot compare a profile with itself")
    end
  end

  describe "profile not found" do
    it "returns not found message for token_a" do
      p = store(build_profile)
      result = call({ "token_a" => "nonexistent", "token_b" => p.token })
      expect(result.first[:text]).to include("Profile not found: nonexistent")
    end

    it "returns not found message for token_b" do
      p = store(build_profile)
      result = call({ "token_a" => p.token, "token_b" => "nonexistent" })
      expect(result.first[:text]).to include("Profile not found: nonexistent")
    end
  end

  describe "valid comparison" do
    it "returns markdown with scorecard" do
      a = store(build_profile(duration: 200.0))
      b = store(build_profile(duration: 100.0))
      result = call({ "token_a" => a.token, "token_b" => b.token })
      text = result.first[:text]
      expect(text).to include("# Profile Comparison")
      expect(text).to include("Scorecard")
      expect(text).to include("Duration")
    end

    it "includes profile tokens in the output" do
      a = store(build_profile)
      b = store(build_profile)
      result = call({ "token_a" => a.token, "token_b" => b.token })
      expect(result.first[:text]).to include(a.token)
      expect(result.first[:text]).to include(b.token)
    end

    it "marks improved duration with check mark" do
      a = store(build_profile(duration: 200.0))
      b = store(build_profile(duration: 100.0))
      result = call({ "token_a" => a.token, "token_b" => b.token })
      expect(result.first[:text]).to include("✅")
    end

    it "marks regressed duration with cross mark" do
      a = store(build_profile(duration: 100.0))
      b = store(build_profile(duration: 200.0))
      result = call({ "token_a" => a.token, "token_b" => b.token })
      expect(result.first[:text]).to include("❌")
    end

    it "warns when endpoints differ" do
      a = store(build_profile(path: "/users"))
      b = store(build_profile(path: "/posts"))
      result = call({ "token_a" => a.token, "token_b" => b.token })
      expect(result.first[:text]).to include("different endpoints")
    end

    it "does not warn when endpoints are the same" do
      a = store(build_profile(path: "/users", method: "GET"))
      b = store(build_profile(path: "/users", method: "GET"))
      result = call({ "token_a" => a.token, "token_b" => b.token })
      expect(result.first[:text]).not_to include("different endpoints")
    end

    it "includes database section when data is present" do
      a = store(build_profile(collectors_data: { "database" => { "total_queries" => 10, "total_duration" => 50.0 } }))
      b = store(build_profile(collectors_data: { "database" => { "total_queries" => 5, "total_duration" => 25.0 } }))
      result = call({ "token_a" => a.token, "token_b" => b.token })
      expect(result.first[:text]).to include("## Database")
    end
  end

  describe "across nodes" do
    let(:peer_token) { "peer-token-0123456789abcdefghijklmnopqr" }

    before do
      Profiler.configure do |c|
        c.peers = [{ name: "staging", url: "https://staging.example.com" }]
        c.peer_token = peer_token
      end
    end

    it "refuses a node outside config.peers with a clear error and no HTTP call" do
      a = store(build_profile)
      expect(Net::HTTP).not_to receive(:start)
      result = call({ "token_a" => a.token, "token_b" => "b" * 32, "node_b" => "prod" })
      expect(result.first[:text]).to match(/Error: Unknown node "prod".*config.peers/)
    end

    it "refuses an URL as a node" do
      a = store(build_profile)
      expect(Net::HTTP).not_to receive(:start)
      result = call({ "token_a" => a.token, "token_b" => "b" * 32, "node_b" => "https://evil.example.com" })
      expect(result.first[:text]).to include("Error: Unknown node")
    end

    it "refuses when peer_token is not configured" do
      Profiler.configuration.peer_token = nil
      a = store(build_profile)
      expect(Net::HTTP).not_to receive(:start)
      result = call({ "token_a" => a.token, "token_b" => "b" * 32, "node_b" => "staging" })
      expect(result.first[:text]).to include("No config.peer_token")
    end

    it "renders the SQL blocks and the nodes with a peer double" do
      queries = [{ "sql" => "SELECT 1 FROM only_b", "duration" => 3.0 }]
      a = store(build_profile)
      remote = build_profile(collectors_data: { "database" => { "queries" => queries } })
      proxy = instance_double(Profiler::Peers::PeerProxy, load: remote)
      allow(Profiler::Peers::PeerProxy).to receive(:new).with("staging").and_return(proxy)

      text = call({ "token_a" => a.token, "token_b" => remote.token, "node_b" => "staging" }).first[:text]
      expect(text).to include("on staging").and include("on local")
      expect(text).to include("New queries (only in B)").and include("SELECT ? FROM only_b")
      expect(text).to include("Gone queries").and include("Slower queries")
    end
  end
end
