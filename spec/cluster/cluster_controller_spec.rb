# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Api::ClusterController, type: :request do
  let(:secret) { "spec-secret-0123456789abcdefghijklmnop" }
  let(:log) { StringIO.new }

  before do
    Profiler.configure do |config|
      config.cluster_secret = secret
      config.logger = Logger.new(log)
    end
    Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
  end

  describe "POST /_profiler/api/cluster/heartbeat" do
    it "warns when heartbeat is received for an unknown slave" do
      post "/_profiler/api/cluster/heartbeat",
           params: { name: "unknown-slave" },
           headers: { "X-Profiler-Cluster-Secret" => secret }

      expect(response).to have_http_status(:not_found)
      expect(log.string).to include("Cluster: received heartbeat for unknown slave 'unknown-slave'")
      expect(log.string).to include("possible multi-worker misconfiguration")
    end

    it "does not warn when heartbeat is for a registered slave" do
      Profiler.slave_registry.register(name: "known-slave", url: "http://localhost:3001")

      post "/_profiler/api/cluster/heartbeat",
           params: { name: "known-slave" },
           headers: { "X-Profiler-Cluster-Secret" => secret }

      expect(response).to have_http_status(:ok)
      expect(log.string).not_to include("received heartbeat for unknown slave")
    end
  end
end
