# frozen_string_literal: true

require "spec_helper"
require "profiler/sse/event_bus"

RSpec.describe Profiler::SSE::EventBus do
  subject(:bus) { described_class.instance }

  before { bus.reset! }

  describe "#version" do
    it "is 0 for a token never saved" do
      expect(bus.version("tok")).to eq(0)
    end

    it "is the version the last broadcast returned" do
      version = bus.broadcast("tok")

      expect(bus.version("tok")).to eq(version)
    end

    it "only moves for the token saved" do
      bus.broadcast("tok-a")

      expect(bus.version("tok-b")).to eq(0)
    end

    it "answers at once" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      bus.version("tok")

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.1
    end
  end

  describe "#broadcast" do
    it "gives every save a newer version, even within one microsecond" do
      versions = Array.new(50) { bus.broadcast("tok") }

      expect(versions.each_cons(2)).to all(satisfy { |older, newer| newer > older })
    end

    it "gives versions that the other worker processes of the machine can compare with" do
      # The time of the save, so a version from another process is not mistaken for newer.
      before_save = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
      version = bus.broadcast("tok")

      expect(version).to be >= before_save
      expect(version).to be <= Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
    end

    it "forgets the oldest saved tokens past MAX_TOKENS" do
      stub_const("#{described_class}::MAX_TOKENS", 3)
      %w[a b c].each { |token| bus.broadcast(token) }
      bus.broadcast("a")
      bus.broadcast("d")

      expect(bus.version("b")).to eq(0)
      expect([bus.version("a"), bus.version("c"), bus.version("d")]).to all(be > 0)
    end
  end
end
