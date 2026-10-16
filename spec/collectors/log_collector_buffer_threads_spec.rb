# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/log_collector"

RSpec.describe Profiler::Collectors::LogCollector::Buffer do
  it "stays within its cap when several threads record at once" do
    buffer = described_class.new(1000)
    threads = Array.new(8) do
      Thread.new { 200.times { buffer.record(level: "INFO", message: "x" * 10, timestamp: "t") } }
    end
    threads.each(&:join)

    expect(buffer.bytes).to eq(1000)
    expect(buffer.sum { |e| e[:message].bytesize }).to eq(1000)
    expect(buffer.size + buffer.dropped).to eq(1600)
  end
end

RSpec.describe Profiler::Collectors::LogCollector::CaptureLogger do
  it "does not change the level of the logger it is attached to" do
    logger = Logger.new(File::NULL)
    logger.level = Logger::WARN
    collector = Profiler::Collectors::LogCollector.new(Profiler::Models::Profile.new)
    stub_const("Rails", double(logger: logger))
    collector.subscribe
    collector.unsubscribe

    expect(logger.level).to eq(Logger::WARN)
  end
end
