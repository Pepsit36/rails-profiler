# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/log_collector"

# The CaptureLogger level is isolated from the global Rails.logger level to prevent
# the BroadcastLogger from forcing DEBUG level globally for all threads.
RSpec.describe Profiler::Collectors::LogCollector, "level isolation" do
  let(:profile) { Profiler::Models::Profile.new }
  let(:collector) { described_class.new(profile) }

  after do
    collector.unsubscribe if @subscribed
    Thread.current[:profiler_logs] = nil
  end

  it "sets CaptureLogger level to match broadcaster level after subscription" do
    skip "Rails.logger not available" unless defined?(Rails) && Rails.logger

    original_level = Rails.logger.level
    Rails.logger.level = Logger::WARN

    collector.subscribe
    @subscribed = true

    expect(collector.instance_variable_get(:@capture_logger)).to be_a(Profiler::Collectors::LogCollector::CaptureLogger)
    expect(collector.instance_variable_get(:@capture_logger).level).to eq(Logger::WARN)
  ensure
    Rails.logger.level = original_level if defined?(Rails) && Rails.logger
  end

  it "does not change Rails.logger level during capture" do
    skip "Rails.logger not available" unless defined?(Rails) && Rails.logger

    original_level = Rails.logger.level
    Rails.logger.level = Logger::INFO

    collector.subscribe
    @subscribed = true

    # Verify that Rails.logger level has not changed during subscription
    expect(Rails.logger.level).to eq(Logger::INFO)

    collector.unsubscribe
    @subscribed = false

    # Verify that Rails.logger level remains unchanged after unsubscribe
    expect(Rails.logger.level).to eq(Logger::INFO)
  ensure
    Rails.logger.level = original_level if defined?(Rails) && Rails.logger
  end

  it "isolates capture logger from broadcaster level changes" do
    skip "Rails.logger not available" unless defined?(Rails) && Rails.logger

    original_level = Rails.logger.level
    Rails.logger.level = Logger::INFO

    collector.subscribe
    @subscribed = true

    capture_logger = collector.instance_variable_get(:@capture_logger)
    initial_capture_level = capture_logger.level

    # Change the broadcaster (Rails.logger) level
    Rails.logger.level = Logger::DEBUG

    # The capture logger level should remain at its original level (not forced to DEBUG)
    expect(capture_logger.level).to eq(initial_capture_level)
    expect(Rails.logger.level).to eq(Logger::DEBUG)
  ensure
    Rails.logger.level = original_level if defined?(Rails) && Rails.logger
  end
end
