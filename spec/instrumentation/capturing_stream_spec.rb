# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "profiler/instrumentation/capturing_stream"

RSpec.describe Profiler::Instrumentation::CapturingStream do
  let(:data) { "0123456789" * 10 }
  let(:io) { StringIO.new(data) }

  it "passes every byte through whatever the read style, and copies up to one past the limit" do
    stream = described_class.new(io, 30)
    out = +""
    out << stream.read(7)
    buf = +""
    out << stream.read(20, buf)
    expect(buf).to eq(out[7, 20])
    out << stream.readpartial(10)
    out << stream.read
    expect(out).to eq(data)
    expect(stream.captured).to eq(data[0, 31])
    expect(stream.total_read).to eq(100)
    expect(stream).to be_finished
  end

  it "works under IO.copy_stream and does not expose to_io" do
    stream = described_class.new(io, 50)
    sink = StringIO.new
    IO.copy_stream(stream, sink)
    expect(sink.string).to eq(data)
    expect(stream.captured).to eq(data[0, 51])
    expect(stream).not_to respond_to(:to_io)
  end

  it "delegates eof?, size and the rest, and forgets what it copied on rewind" do
    stream = described_class.new(io, 50)
    stream.read(10)
    expect(stream.size).to eq(100)
    expect(stream.eof?).to be(false)
    stream.rewind
    expect(stream.captured).to eq("")
    expect(stream.read(3)).to eq("012")
    expect(stream.captured).to eq("012")
    expect { stream.nothing_like_this }.to raise_error(NoMethodError)
  end

  it "does not claim to rewind a stream that cannot" do
    plain = Class.new { def read(*) = nil }.new
    expect(described_class.new(plain, 5)).to be_respond_to(:read)
    expect { described_class.new(plain, 5).size }.to raise_error(NoMethodError)
  end
end
