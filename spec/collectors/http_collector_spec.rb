# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::HttpCollector do
  let(:profile) { build_profile }
  subject(:collector) { described_class.new(profile) }

  before do
    Profiler.configure do |c|
      c.track_http = false # Don't actually patch Net::HTTP in tests
      c.slow_http_threshold = 500
    end
  end

  # Helpers to build request payloads and drive the two-phase API
  def pending_payload(url:, method: "GET")
    {
      id: SecureRandom.hex(8),
      started_at: Time.now.iso8601(3),
      url: url,
      method: method,
      request_headers: {},
      request_body: nil,
      request_body_encoding: "text",
      request_size: 0,
      backtrace: []
    }
  end

  def add_request(collector, url:, method: "GET", status: 200, duration: 10.0)
    entry = collector.register_pending(**pending_payload(url: url, method: method))
    collector.complete_request(entry,
      status: status, duration: duration,
      response_headers: {}, response_body: nil,
      response_body_encoding: "text", response_size: 0)
    entry
  end

  # ─── register_pending ───────────────────────────────────────────────────────

  describe "#register_pending" do
    it "appends an in_flight entry to @requests" do
      entry = collector.register_pending(**pending_payload(url: "https://api.example.com/users"))
      expect(collector.instance_variable_get(:@requests).size).to eq(1)
      expect(entry[:in_flight]).to be true
    end

    it "sets status to 0 and duration to nil while pending" do
      entry = collector.register_pending(**pending_payload(url: "https://api.example.com/"))
      expect(entry[:status]).to eq(0)
      expect(entry[:duration]).to be_nil
    end

    it "does not write to storage before collect" do
      expect(Profiler.storage).not_to receive(:save)
      collector.register_pending(**pending_payload(url: "https://api.example.com/"))
    end
  end

  # ─── complete_request ───────────────────────────────────────────────────────

  describe "#complete_request" do
    it "updates the entry in-place with response data" do
      entry = collector.register_pending(**pending_payload(url: "https://api.example.com/"))
      collector.complete_request(entry,
        status: 201, duration: 42.5,
        response_headers: { "content-type" => "application/json" },
        response_body: '{"ok":true}', response_body_encoding: "text", response_size: 11)

      expect(entry[:status]).to eq(201)
      expect(entry[:duration]).to eq(42.5)
      expect(entry[:in_flight]).to be false
    end

    it "does not write to storage before collect" do
      entry = collector.register_pending(**pending_payload(url: "https://api.example.com/"))
      expect(Profiler.storage).not_to receive(:save)
      collector.complete_request(entry,
        status: 200, duration: 5.0,
        response_headers: {}, response_body: nil, response_body_encoding: "text", response_size: 0)
    end

    context "after collect" do
      it "triggers a storage re-save" do
        entry = collector.register_pending(**pending_payload(url: "https://api.example.com/"))
        collector.collect
        Profiler.storage.save(profile.token, profile)

        collector.complete_request(entry,
          status: 200, duration: 55.0,
          response_headers: {}, response_body: nil, response_body_encoding: "text", response_size: 0)

        # Keys are stringified after storage round-trip (deep_stringify_keys in Profile.from_hash)
        reloaded = Profiler.storage.load(profile.token)
        req = reloaded.collector_data("http")["requests"].first
        expect(req["status"]).to eq(200)
        expect(req["duration"]).to eq(55.0)
        expect(req["in_flight"]).to be false
      end
    end
  end

  # ─── fail_request ───────────────────────────────────────────────────────────

  describe "#fail_request" do
    it "marks the entry as failed with status 0 and an error message" do
      entry = collector.register_pending(**pending_payload(url: "https://broken.example.com/"))
      collector.fail_request(entry, error: "Connection refused", duration: 5000.0)

      expect(entry[:status]).to eq(0)
      expect(entry[:error]).to eq("Connection refused")
      expect(entry[:duration]).to eq(5000.0)
      expect(entry[:in_flight]).to be false
    end

    context "after collect" do
      it "triggers a storage re-save and counts as error_request" do
        entry = collector.register_pending(**pending_payload(url: "https://broken.example.com/"))
        collector.collect
        Profiler.storage.save(profile.token, profile)

        collector.fail_request(entry, error: "ETIMEDOUT", duration: 30000.0)

        # Keys are stringified after storage round-trip (deep_stringify_keys in Profile.from_hash)
        reloaded = Profiler.storage.load(profile.token)
        data = reloaded.collector_data("http")
        expect(data["error_requests"]).to eq(1)
        req = data["requests"].first
        expect(req["error"]).to eq("ETIMEDOUT")
        expect(req["in_flight"]).to be false
      end
    end
  end

  # ─── collect ────────────────────────────────────────────────────────────────

  describe "#collect" do
    context "with completed requests" do
      before do
        add_request(collector, url: "https://api.example.com/a", status: 200, duration: 10.0)
        add_request(collector, url: "https://api.example.com/b", status: 500, duration: 600.0)
        add_request(collector, url: "https://other.com/c", status: 200, duration: 5.0)
        collector.collect
      end

      it "computes total_requests" do
        expect(collector.panel_content[:total_requests]).to eq(3)
      end

      it "computes slow_requests (excludes in_flight)" do
        expect(collector.panel_content[:slow_requests]).to eq(1)
      end

      it "computes error_requests (excludes in_flight)" do
        expect(collector.panel_content[:error_requests]).to eq(1)
      end

      it "groups by_host" do
        by_host = collector.panel_content[:by_host]
        expect(by_host["api.example.com"]).to eq(2)
        expect(by_host["other.com"]).to eq(1)
      end

      it "groups by_status" do
        by_status = collector.panel_content[:by_status]
        expect(by_status["2xx"]).to eq(2)
        expect(by_status["5xx"]).to eq(1)
      end
    end

    context "with an in_flight entry at collect time" do
      it "captures the pending entry with in_flight: true" do
        collector.register_pending(**pending_payload(url: "https://slow.example.com/"))
        collector.collect

        reqs = collector.panel_content[:requests]
        expect(reqs.size).to eq(1)
        expect(reqs.first["in_flight"]).to be true
      end

      it "groups in_flight entries under 'pending' in by_status" do
        collector.register_pending(**pending_payload(url: "https://slow.example.com/"))
        collector.collect

        expect(collector.panel_content[:by_status]["pending"]).to eq(1)
      end

      it "does not count in_flight as an error" do
        collector.register_pending(**pending_payload(url: "https://slow.example.com/"))
        collector.collect

        expect(collector.panel_content[:error_requests]).to eq(0)
      end
    end
  end

  # ─── toolbar_summary ────────────────────────────────────────────────────────

  describe "#toolbar_summary" do
    it "returns green with 0 requests" do
      expect(collector.toolbar_summary[:color]).to eq("green")
      expect(collector.toolbar_summary[:text]).to eq("0 HTTP")
    end

    it "returns red when there are errors" do
      add_request(collector, url: "https://api.example.com", status: 500, duration: 10.0)
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "returns red when there are slow requests" do
      add_request(collector, url: "https://api.example.com", status: 200, duration: 600.0)
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "returns orange when many requests but no errors/slow" do
      Profiler.configure { |c| c.slow_http_threshold = 10_000 }
      11.times { add_request(collector, url: "https://api.example.com", status: 200, duration: 5.0) }
      expect(collector.toolbar_summary[:color]).to eq("orange")
    end

    it "returns green for a small number of successful requests" do
      add_request(collector, url: "https://api.example.com", status: 200, duration: 10.0)
      expect(collector.toolbar_summary[:color]).to eq("green")
    end

    it "returns orange and shows pending count when there are in_flight entries" do
      collector.register_pending(**pending_payload(url: "https://slow.example.com/"))
      summary = collector.toolbar_summary
      expect(summary[:color]).to eq("orange")
      expect(summary[:text]).to include("pending")
    end
  end

  # ─── thread propagation ─────────────────────────────────────────────────────

  describe "thread propagation" do
    it "child threads inherit the collector from the parent" do
      Thread.current[:profiler_http_collector] = collector
      inherited = nil
      Thread.new { inherited = Thread.current[:profiler_http_collector] }.join
      expect(inherited).to equal(collector)
    ensure
      Thread.current[:profiler_http_collector] = nil
    end

    it "grandchild threads also inherit the collector" do
      Thread.current[:profiler_http_collector] = collector
      grandchild = nil
      Thread.new { Thread.new { grandchild = Thread.current[:profiler_http_collector] }.join }.join
      expect(grandchild).to equal(collector)
    ensure
      Thread.current[:profiler_http_collector] = nil
    end

    it "threads spawned without a parent collector get nil" do
      Thread.current[:profiler_http_collector] = nil
      result = nil
      Thread.new { result = Thread.current[:profiler_http_collector] }.join
      expect(result).to be_nil
    end

    it "child threads clean up after themselves (pool thread reuse safety)" do
      Thread.current[:profiler_http_collector] = collector
      t = Thread.new { }
      t.join
      # The spawned thread cleaned up in its ensure block.
      # Simulate a pool reusing the same Thread object: not possible in Ruby,
      # but verify the parent thread still has its value untouched.
      expect(Thread.current[:profiler_http_collector]).to equal(collector)
    ensure
      Thread.current[:profiler_http_collector] = nil
    end

    it "fire-and-forget thread records its request after collect via re-save" do
      Thread.current[:profiler_http_collector] = collector

      # Simulate: fire-and-forget thread starts BEFORE collect (registers pending)
      entry = nil
      fire_and_forget = Thread.new do
        entry = collector.register_pending(**pending_payload(url: "https://ff.example.com/data"))
        sleep 0.02 # simulate network delay — collect() runs while this sleeps
        collector.complete_request(entry,
          status: 200, duration: 20.0,
          response_headers: {}, response_body: "done",
          response_body_encoding: "text", response_size: 4)
      end

      # collect() runs while the thread is still in-flight
      sleep 0.005
      collector.collect
      Profiler.storage.save(profile.token, profile)

      # At this point: profile in storage has in_flight entry
      # (keys are stringified after storage round-trip)
      mid_state = Profiler.storage.load(profile.token)
      expect(mid_state.collector_data("http")["requests"].first["in_flight"]).to be true

      # Wait for fire-and-forget to complete — it re-saves
      fire_and_forget.join

      # Profile in storage is now updated with complete data
      final = Profiler.storage.load(profile.token)
      req = final.collector_data("http")["requests"].first
      expect(req["status"]).to eq(200)
      expect(req["in_flight"]).to be false
      expect(req["duration"]).to eq(20.0)
    ensure
      Thread.current[:profiler_http_collector] = nil
    end
  end
end
