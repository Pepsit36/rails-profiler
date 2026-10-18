# frozen_string_literal: true

require "spec_helper"
require "rack/test"

RSpec.describe "Collector isolation and circuit breaker" do
  let(:breaker) { Profiler::Collectors::CircuitBreaker }

  let(:healthy_class) do
    Class.new(Profiler::Collectors::BaseCollector) do
      def self.name = "Profiler::Collectors::HealthyCollector"
      def collect = store_data({ "ok" => true })
    end
  end

  let(:broken_class) do
    Class.new(Profiler::Collectors::BaseCollector) do
      def self.name = "Profiler::Collectors::BrokenCollector"
      def subscribe = raise("cannot subscribe")
    end
  end

  let(:collect_broken_class) do
    Class.new(Profiler::Collectors::BaseCollector) do
      def self.name = "Profiler::Collectors::CollectBrokenCollector"
      def collect = raise("cannot collect")
    end
  end

  before { Profiler.configure { |c| c.enabled = true } }

  describe Profiler::Collectors::Lifecycle do
    it "keeps the collectors that subscribed when one fails" do
      profile = build_profile
      healthy = healthy_class.new(profile)
      broken = broken_class.new(profile)
      collectors = [broken, healthy]

      expect(described_class.subscribe_all(collectors, "Test")).to be true
      expect(collectors).to eq([healthy])
    end

    it "reports false only when no collector could subscribe" do
      collectors = [broken_class.new(build_profile)]

      expect(described_class.subscribe_all(collectors, "Test")).to be false
      expect(collectors).to be_empty
    end

    it "releases the collector that failed to subscribe" do
      broken = broken_class.new(build_profile)
      expect(broken).to receive(:unsubscribe)

      described_class.subscribe_all([broken], "Test")
    end
  end

  describe "through the middleware" do
    include Rack::Test::Methods

    let(:inner_app) { ->(_env) { [200, { "Content-Type" => "text/html" }, ["<html><body>hi</body></html>"]] } }

    def app = Profiler::Middleware::ProfilerMiddleware.new(inner_app)

    def default_host = "localhost"

    let(:store) { Profiler::Storage::MemoryStore.new }

    before do
      Profiler.configure do |c|
        c.skip_paths = []
        c.track_memory = false
        c.track_http = false
      end
      Profiler.instance_variable_set(:@storage, store)
    end

    it "still profiles the request with the healthy collectors when another one cannot subscribe" do
      Profiler.configuration.collectors = [broken_class, healthy_class]

      get "/users"

      expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
      expect(store.list(limit: 1).first.collector_data("healthy")).to eq("ok" => true)
    end

    it "stops instantiating a collector after the threshold, and tries it again once the delay has passed" do
      Profiler.configuration.collectors = [broken_class, healthy_class]
      Profiler.configuration.collector_circuit_breaker_threshold = 3
      instantiations = 0
      allow(broken_class).to receive(:new).and_wrap_original { |m, *a| instantiations += 1; m.call(*a) }

      3.times { get "/users" }
      expect(instantiations).to eq(3)
      expect(breaker.status(broken_class)).to eq(state: :open, failures: 3)

      2.times { get "/users" }
      expect(instantiations).to eq(3)
      expect(store.list(limit: 1).first.collector_data("broken")).to be_nil

      now = breaker.now
      allow(breaker).to receive(:now).and_return(now + 61)
      expect(breaker.status(broken_class)[:state]).to eq(:half_open)

      get "/users"
      expect(instantiations).to eq(4)
      # The trial failed: open again, for another delay.
      expect(breaker.status(broken_class)[:state]).to eq(:open)
      get "/users"
      expect(instantiations).to eq(4)
    end

    it "counts a collect failure and closes the circuit again after a successful trial" do
      Profiler.configuration.collectors = [collect_broken_class]
      Profiler.configuration.collector_circuit_breaker_threshold = 2

      2.times { get "/users" }
      expect(breaker.status(collect_broken_class)).to eq(state: :open, failures: 2)

      allow(breaker).to receive(:now).and_return(breaker.now + 61)
      collect_broken_class.send(:define_method, :collect) { store_data({}) }
      get "/users"

      expect(breaker.status(collect_broken_class)).to eq(state: :closed, failures: 0)
    end

    it "lets one trial through at a time while half open" do
      Profiler.configuration.collector_circuit_breaker_threshold = 1
      breaker.record_failure(broken_class)
      allow(breaker).to receive(:now).and_return(breaker.now + 61)

      expect(breaker.allow?(broken_class)).to be true
      expect(breaker.allow?(broken_class)).to be false
    end

    it "resets the count on a success" do
      breaker.record_failure(healthy_class)
      breaker.record_failure(healthy_class)
      breaker.record_success(healthy_class)

      expect(breaker.status(healthy_class)).to eq(state: :closed, failures: 0)
    end

    it "counts and blocks nothing when disabled" do
      Profiler.configuration.collector_circuit_breaker_enabled = false
      Profiler.configuration.collectors = [broken_class, healthy_class]

      5.times { get "/users" }

      expect(breaker.status(broken_class)).to eq(state: :closed, failures: 0)
      expect(breaker.allow?(broken_class)).to be true
      expect(store.list(limit: 1).first.collector_data("healthy")).to eq("ok" => true)
    end
  end

  describe "the options" do
    it "defaults to enabled with a threshold of 3" do
      expect(Profiler.configuration.collector_circuit_breaker_enabled).to be true
      expect(Profiler.configuration.collector_circuit_breaker_threshold).to eq(3)
    end

    it "keeps the previous threshold and warns when given something that is not a positive Integer" do
      expect(Profiler).to receive(:log_warn).with(/collector_circuit_breaker_threshold/).twice

      Profiler.configuration.collector_circuit_breaker_threshold = 0
      Profiler.configuration.collector_circuit_breaker_threshold = "5"

      expect(Profiler.configuration.collector_circuit_breaker_threshold).to eq(3)
    end
  end
end
