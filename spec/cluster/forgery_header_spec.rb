# frozen_string_literal: true

require "spec_helper"
require "profiler/cluster/slave_registry"
require "profiler/cluster/slave_proxy"
require "profiler/cluster/master_client"

# A master and its slaves call each other's API, which refuses a mutation that does not
# carry the forgery protection header.
RSpec.describe "Cluster requests and forgery protection" do
  let(:ok) { instance_double(Net::HTTPResponse, code: "200", body: "{}") }

  describe Profiler::Cluster::SlaveProxy do
    before do
      # A master that lets these slaves through: secret configured, URLs allowed.
      Profiler.configure do |config|
        config.cluster_secret = "spec-secret"
        config.cluster_allowed_slave_urls = %w[http://payment:3001 http://trailing:3001]
        config.cluster_allow_insecure_http = true
      end
      Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
      Profiler.slave_registry.register(name: "payment", url: "http://payment:3001")
    end

    after { Profiler.instance_variable_set(:@slave_registry, nil) }

    it "sends the header on every verb" do
      sent = []
      http = double("http")
      allow(http).to receive(:request) { |req| sent << req; ok }
      allow(Net::HTTP).to receive(:start).and_yield(http)

      proxy = described_class.new("payment")
      proxy.get_json("/_profiler/api/profiles")
      proxy.post_json("/_profiler/api/explain", token: "t")
      proxy.patch_json("/_profiler/api/env_vars", key: "K")
      proxy.delete_json("/_profiler/api/profiles/clear")

      expect(sent.map(&:method)).to eq(%w[GET POST PATCH DELETE])
      expect(sent.map { |req| req[Profiler::FORGERY_PROTECTION_HEADER] }).to all(eq("1"))
      expect(sent.map { |req| req["X-Profiler-Cluster-Secret"] }).to all(eq("spec-secret"))
    end
  end

  describe Profiler::Cluster::MasterClient do
    before do
      Profiler.configure do |config|
        config.master_url = "http://master:3000"
        config.self_url = "http://slave:3001"
        config.name = "slave"
        config.cluster_secret = "spec-secret"
        config.cluster_allow_insecure_http = true
      end
    end

    it "sends the header when registering and on each heartbeat" do
      allow(Net::HTTP).to receive(:post).and_return(ok)

      client = described_class.new
      client.send(:register!)
      client.send(:heartbeat!)

      expect(Net::HTTP).to have_received(:post)
        .with(anything, anything, hash_including(Profiler::FORGERY_PROTECTION_HEADER => "1",
                                                 "X-Profiler-Cluster-Secret" => "spec-secret")).twice
    end

    it "sends nothing to a remote master over plain HTTP" do
      Profiler.configuration.cluster_allow_insecure_http = false
      allow(Net::HTTP).to receive(:post).and_return(ok)

      expect { described_class.new.send(:register!) }.to raise_error(/HTTPS is required/)
      expect(Net::HTTP).not_to have_received(:post)
    end

    it "sends nothing when no secret is configured" do
      Profiler.configuration.cluster_secret = nil
      allow(Net::HTTP).to receive(:post).and_return(ok)

      expect { described_class.new.send(:heartbeat!) }.to raise_error(/cluster_secret/)
      expect(Net::HTTP).not_to have_received(:post)
    end
  end
end
