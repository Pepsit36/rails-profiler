# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/log_collector"

# A line the application logs is kept as valid UTF-8, whatever its bytes: the capture neither
# raises into the application's logger call nor leaves a line that fails the JSON of the profile.
RSpec.describe Profiler::Collectors::LogCollector, "encodings" do
  let(:profile) { Profiler::Models::Profile.new }
  let(:collector) { described_class.new(profile) }
  let(:capture) { described_class::CaptureLogger.new }

  after { Thread.current[:profiler_logs] = nil }

  def messages
    collector.collect
    profile.collector_data("logs")[:logs].map { |line| line[:message] }
  end

  it "keeps a line that is not valid UTF-8, its bad bytes replaced, without raising into the logger call" do
    collector.subscribe
    broadcast = ActiveSupport::BroadcastLogger.new(ActiveSupport::Logger.new(StringIO.new), capture)

    expect { broadcast.info(" caf\xC3 au lait ".dup.force_encoding(Encoding::UTF_8)) }.not_to raise_error
    expect(messages).to eq(["caf� au lait"])
    expect { profile.to_h.to_json }.not_to raise_error
  end

  it "reads a binary line as UTF-8 when it is, so that the profile can still be saved" do
    collector.subscribe
    capture.add(1, "café".b)
    capture.add(1, "caf\xE9".b)

    expect(messages).to eq(["café", "caf�"])
    expect { profile.to_h.to_json }.not_to raise_error
  end

  it "converts a line in another encoding to UTF-8" do
    collector.subscribe
    capture.add(1, "caf\xE9".dup.force_encoding(Encoding::ISO_8859_1))

    expect(messages).to eq(["café"])
  end

  it "leaves the application's own string untouched" do
    collector.subscribe
    line = "caf\xC3".dup.force_encoding(Encoding::UTF_8)
    capture.add(1, line)

    expect(line.bytes).to eq("caf\xC3".bytes)
    expect(line.encoding).to eq(Encoding::UTF_8)
  end
end
