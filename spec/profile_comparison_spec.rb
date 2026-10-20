# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::ProfileComparison do
  let(:token) { "peer-token-0123456789abcdefghijklmnopqr" }

  before do
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler.configure do |c|
      c.peers = [{ name: "staging", url: "https://staging.example.com" }]
      c.peer_token = token
    end
  end

  def db(queries)
    { "database" => { "queries" => queries, "total_queries" => queries.size } }
  end

  def store(profile)
    Profiler.storage.save(profile.token, profile)
    profile
  end

  it "diffs two local profiles by normalized SQL fingerprint: new, gone, slower" do
    a = store(build_profile(collectors_data: db([
      { "sql" => "SELECT * FROM users WHERE id = 1", "duration" => 10.0 },
      { "sql" => "SELECT * FROM users WHERE id = 2", "duration" => 10.0 },
      { "sql" => "SELECT * FROM old_table", "duration" => 5.0 }
    ])))
    b = store(build_profile(collectors_data: db([
      { "sql" => "SELECT * FROM users WHERE id = 9", "duration" => 30.0 },
      { "sql" => "SELECT * FROM new_table", "duration" => 7.0 }
    ])))

    result = described_class.call(a.token, b.token)
    expect(result[:sql][:new].map { |q| q[:fingerprint] }).to eq(["SELECT * FROM new_table"])
    expect(result[:sql][:gone].map { |q| q[:fingerprint] }).to eq(["SELECT * FROM old_table"])
    slower = result[:sql][:slower].first
    expect(slower[:fingerprint]).to eq("SELECT * FROM users WHERE id = ?")
    expect(slower).to include(count_a: 2, count_b: 1, total_duration_a: 20.0, total_duration_b: 30.0, delta_pct: 50.0)
    expect(result[:profile_a][:node]).to eq("local")
  end

  it "compares allocations, cache hit rate, views and total duration" do
    a = build_profile(duration: 100.0, collectors_data: { "cache" => { "hit_rate" => 80.0 },
                                                          "view" => { "views" => [{ "identifier" => "a.erb" }] } })
    a.allocated_objects = 1000
    b = build_profile(duration: 200.0, collectors_data: { "cache" => { "hit_rate" => 40.0 },
                                                          "view" => { "views" => [{ "identifier" => "b.erb" }] } })
    b.allocated_objects = 3000
    store(a)
    store(b)

    result = described_class.call(a.token, b.token)
    expect(result[:metrics][:duration][:status]).to eq(:regression)
    expect(result[:metrics][:allocated_objects]).to include(value_a: 1000, value_b: 3000, status: :regression)
    expect(result[:metrics][:cache_hit_rate][:status]).to eq(:regression)
    expect(result[:collectors][:views]).to include(views_a: { "a.erb" => 1 }, views_b: { "b.erb" => 1 })
  end

  it "reads each profile from its own node" do
    local = store(build_profile(path: "/local"))
    remote = build_profile(path: "/remote")
    proxy = instance_double(Profiler::Peers::PeerProxy)
    allow(Profiler::Peers::PeerProxy).to receive(:new).with("staging").and_return(proxy)
    allow(proxy).to receive(:load).with(remote.token).and_return(remote)

    result = described_class.call(local.token, remote.token, node_a: "local", node_b: "staging")
    expect(result[:profile_a]).to include(node: "local", path: "/local")
    expect(result[:profile_b]).to include(node: "staging", path: "/remote")
  end

  it "fails on an unknown node before reading anything" do
    local = store(build_profile)
    expect(Profiler.storage).not_to receive(:load)
    expect(Net::HTTP).not_to receive(:start)
    expect { described_class.call(local.token, "b" * 32, node_a: "local", node_b: "https://evil.example.com") }
      .to raise_error(Profiler::Error, /Unknown node/)
  end

  it "reports a profile missing on a node" do
    local = store(build_profile)
    expect { described_class.call(local.token, "c" * 32) }
      .to raise_error(described_class::NotFound, /Profile not found: #{"c" * 32}/)
  end
end
