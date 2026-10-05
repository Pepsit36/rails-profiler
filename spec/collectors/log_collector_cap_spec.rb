# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/log_collector"

# What a request logs is kept up to max_captured_log_bytes: a request, or a stream held open,
# that logs without end no longer grows its thread's buffer without bound.
RSpec.describe Profiler::Collectors::LogCollector, "buffer cap" do
  let(:profile) { Profiler::Models::Profile.new }
  let(:collector) { described_class.new(profile) }
  let(:capture) { described_class::CaptureLogger.new }

  after { Thread.current[:profiler_logs] = nil }

  def logs
    profile.collector_data("logs")
  end

  it "defaults to one megabyte" do
    expect(Profiler::Configuration.new.max_captured_log_bytes).to eq(1024 * 1024)
  end

  context "with a cap" do
    before { Profiler.configuration.max_captured_log_bytes = 1000 }

    it "stops adding lines once the cap is reached, and says how many were left out" do
      collector.subscribe
      500.times { |i| capture.add(1, format("line %04d %s", i, "x" * 40)) }
      expect(Thread.current[:profiler_logs].sum { |line| line[:message].bytesize }).to be <= 1000
      collector.collect

      expect(logs[:truncated]).to be(true)
      expect(logs[:dropped]).to be > 400
      expect(logs[:logs].last[:message]).to match(/\[Profiler\] \d+ more log lines were not recorded \(max_captured_log_bytes\)/)
      expect(logs[:count]).to eq(500)
    end

    it "cuts one very long line, a Parameters: line of a large JSON body, at the cap" do
      collector.subscribe
      capture.add(1, "  Parameters: #{{ "data" => "p" * 5_000_000 }.inspect}")
      collector.collect

      kept = logs[:logs].first[:message]
      expect(kept.bytesize).to be <= 1000
      expect(kept).to start_with("Parameters: {")
      expect(logs[:truncated]).to be(true)
    end

    it "keeps every line when the cap is nil" do
      Profiler.configuration.max_captured_log_bytes = nil
      collector.subscribe
      500.times { |i| capture.add(1, "line #{i} #{"x" * 40}") }
      collector.collect

      expect(logs[:logs].size).to eq(500)
      expect(logs[:truncated]).to be(false)
    end
  end
end
