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

  def make_request(url:, method: "GET", status: 200, duration: 10.0)
    { url: url, method: method, status: status, duration: duration }
  end

  describe "#record_request" do
    it "appends to @requests" do
      collector.record_request(make_request(url: "https://api.example.com/users"))
      expect(collector.instance_variable_get(:@requests).size).to eq(1)
    end
  end

  describe "#collect" do
    before do
      collector.instance_variable_set(:@requests, [
        make_request(url: "https://api.example.com/a", status: 200, duration: 10.0),
        make_request(url: "https://api.example.com/b", status: 500, duration: 600.0),
        make_request(url: "https://other.com/c", status: 200, duration: 5.0)
      ])
    end

    before { collector.collect }

    it "computes total_requests" do
      expect(collector.panel_content[:total_requests]).to eq(3)
    end

    it "computes slow_requests" do
      expect(collector.panel_content[:slow_requests]).to eq(1)
    end

    it "computes error_requests" do
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

  describe "#toolbar_summary" do
    it "returns green with 0 requests" do
      expect(collector.toolbar_summary[:color]).to eq("green")
      expect(collector.toolbar_summary[:text]).to eq("0 HTTP")
    end

    it "returns red when there are errors" do
      collector.instance_variable_set(:@requests, [
        make_request(url: "https://api.example.com", status: 500, duration: 10.0)
      ])
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "returns red when there are slow requests" do
      collector.instance_variable_set(:@requests, [
        make_request(url: "https://api.example.com", status: 200, duration: 600.0)
      ])
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "returns orange when many requests but no errors/slow" do
      Profiler.configure { |c| c.slow_http_threshold = 10_000 }
      requests = 11.times.map { make_request(url: "https://api.example.com", status: 200, duration: 5.0) }
      collector.instance_variable_set(:@requests, requests)
      expect(collector.toolbar_summary[:color]).to eq("orange")
    end

    it "returns green for a small number of successful requests" do
      collector.instance_variable_set(:@requests, [
        make_request(url: "https://api.example.com", status: 200, duration: 10.0)
      ])
      expect(collector.toolbar_summary[:color]).to eq("green")
    end
  end
end
