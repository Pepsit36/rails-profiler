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
    end
  end

  describe Profiler::Cluster::MasterClient do
    before do
      Profiler.configure do |config|
        config.master_url = "http://master:3000"
        config.self_url = "http://slave:3001"
        config.name = "slave"
      end
    end

    it "sends the header when registering and on each heartbeat" do
      allow(Net::HTTP).to receive(:post).and_return(ok)

      client = described_class.new
      client.send(:register!)
      client.send(:heartbeat!)

      expect(Net::HTTP).to have_received(:post)
        .with(anything, anything, hash_including(Profiler::FORGERY_PROTECTION_HEADER => "1")).twice
    end
  end
end
