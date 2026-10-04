# frozen_string_literal: true

require "spec_helper"
require "profiler/cluster/slave_registry"
require "profiler/cluster/slave_proxy"

RSpec.describe Profiler::Cluster::SlaveProxy do
  before do
    # A master that lets these slaves through: secret configured, URLs allowed.
    Profiler.configure do |config|
      config.cluster_secret = "spec-secret-0123456789abcdefghijklmnop"
      config.cluster_allowed_slave_urls = %w[http://payment:3001 http://trailing:3001]
      config.cluster_allow_insecure_http = true
    end
    Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
    Profiler.slave_registry.register(name: "payment", url: "http://payment:3001")
  end

  subject(:proxy) { described_class.new("payment") }

  describe ".new" do
    it "raises for an unknown slave" do
      expect { described_class.new("ghost") }.to raise_error(Profiler::Error, /Unknown slave/)
    end

    it "raises when the slave is offline" do
      entry = Profiler.slave_registry.register(name: "stale", url: "http://stale:3001")
      entry.last_heartbeat_at = Time.now - 999
      expect { described_class.new("stale") }.to raise_error(Profiler::Error, /offline/)
    end

    it "strips a trailing slash from the slave url" do
      Profiler.slave_registry.register(name: "trailing", url: "http://trailing:3001/")
      expect(described_class.new("trailing").instance_variable_get(:@base_url)).to eq("http://trailing:3001")
    end
  end

  describe "#list" do
    # Regression: the proxy must mirror Profiler.storage.list, which returns ALL
    # profile types. Querying only http would make query_jobs/tests/console via a
    # slave silently return nothing.
    it "requests all profile types" do
      allow(proxy).to receive(:get_json).and_return({ "profiles" => [] })
      proxy.list(limit: 10)
      expect(proxy).to have_received(:get_json).with(
        "/_profiler/api/profiles", hash_including(all_types: true)
      )
    end

    it "maps the response into Profile objects of any type" do
      allow(proxy).to receive(:get_json).and_return(
        "profiles" => [
          {
            "token" => "job1", "profile_type" => "job", "path" => "/work",
            "method" => "JOB", "status" => 200, "duration" => 1.0,
            "started_at" => Time.now.iso8601
          }
        ]
      )
      result = proxy.list(limit: 10)
      expect(result.first).to be_a(Profiler::Models::Profile)
      expect(result.first.profile_type).to eq("job")
    end
  end

  describe "#load" do
    it "returns nil when the slave has no such profile" do
      allow(proxy).to receive(:get_json).and_return("error" => "Profile not found")
      expect(proxy.load("missing")).to be_nil
    end

    it "builds a Profile from the slave payload" do
      allow(proxy).to receive(:get_json).and_return(
        "token" => "abc", "profile_type" => "http", "path" => "/x",
        "method" => "GET", "status" => 200, "duration" => 2.0,
        "started_at" => Time.now.iso8601
      )
      expect(proxy.load("abc")).to be_a(Profiler::Models::Profile)
    end
  end

  describe "#find_by_parent" do
    it "requests profiles filtered by parent_token with all_types" do
      allow(proxy).to receive(:get_json).and_return({ "profiles" => [] })
      proxy.find_by_parent("parent-tok")
      expect(proxy).to have_received(:get_json).with(
        "/_profiler/api/profiles", hash_including(parent_token: "parent-tok", all_types: true)
      )
    end

    it "returns an array of Profile objects" do
      allow(proxy).to receive(:get_json).and_return(
        "profiles" => [
          {
            "token" => "job1", "profile_type" => "job", "path" => "/work",
            "method" => "JOB", "status" => 200, "duration" => 1.0,
            "started_at" => Time.now.iso8601
          }
        ]
      )
      result = proxy.find_by_parent("parent-tok")
      expect(result.size).to eq(1)
      expect(result.first).to be_a(Profiler::Models::Profile)
      expect(result.first.profile_type).to eq("job")
    end

    it "returns an empty array when no children exist" do
      allow(proxy).to receive(:get_json).and_return({ "profiles" => [] })
      expect(proxy.find_by_parent("no-children")).to eq([])
    end
  end

  describe "timeout overrides" do
    it "uses custom open/read timeouts when provided" do
      proxy_with_timeouts = described_class.new("payment", open_timeout: 2, read_timeout: 3)
      expect(proxy_with_timeouts.instance_variable_get(:@open_timeout)).to eq(2)
      expect(proxy_with_timeouts.instance_variable_get(:@read_timeout)).to eq(3)
    end

    it "falls back to constants when no overrides given" do
      expect(proxy.instance_variable_get(:@open_timeout)).to eq(Profiler::Cluster::SlaveProxy::OPEN_TIMEOUT)
      expect(proxy.instance_variable_get(:@read_timeout)).to eq(Profiler::Cluster::SlaveProxy::READ_TIMEOUT)
    end
  end
end
