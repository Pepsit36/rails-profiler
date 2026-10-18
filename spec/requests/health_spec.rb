# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

RSpec.describe "GET /_profiler/health", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:breaker) { Profiler::Collectors::CircuitBreaker }
  let(:flaky) do
    Class.new(Profiler::Collectors::BaseCollector) { def self.name = "Profiler::Collectors::FlakyCollector" }
  end

  def app = Rails.application

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = [flaky, Profiler::Collectors::LogCollector]
      config.collector_circuit_breaker_threshold = 2
    end
    2.times { breaker.record_failure(flaky) }
  end

  it "answers JSON with the state of each collector and the options" do
    get "/_profiler/health.json", {}, local

    expect(last_response.status).to eq(200)
    body = JSON.parse(last_response.body)
    expect(body["circuit_breaker"]).to eq("enabled" => true, "threshold" => 2)
    expect(body["collectors"]).to eq([
      { "name" => "Profiler::Collectors::FlakyCollector", "state" => "open", "failures" => 2 },
      { "name" => "Profiler::Collectors::LogCollector", "state" => "closed", "failures" => 0 }
    ])
  end

  it "answers HTML with the same data" do
    get "/_profiler/health", {}, local.merge("HTTP_ACCEPT" => "text/html")

    expect(last_response.status).to eq(200)
    expect(last_response.content_type).to include("text/html")
    expect(last_response.body).to include("FlakyCollector", "open", "LogCollector", "closed")
  end

  it "shows a circuit past its delay as half open" do
    allow(breaker).to receive(:now).and_return(breaker.now + 61)

    get "/_profiler/health.json", {}, local

    expect(JSON.parse(last_response.body)["collectors"].first["state"]).to eq("half_open")
  end
end
