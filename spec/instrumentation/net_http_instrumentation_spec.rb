# frozen_string_literal: true

require "spec_helper"
require "profiler/instrumentation/net_http_instrumentation"

RSpec.describe Profiler::Instrumentation::NetHttpInstrumentation do
  describe ".extract_backtrace" do
    it "returns at most http_backtrace_depth frames" do
      allow(Profiler.configuration).to receive(:http_backtrace_depth).and_return(3)
      result = described_class.extract_backtrace
      expect(result.length).to be <= 3
    end

    it "returns all frames when http_backtrace_depth is nil" do
      allow(Profiler.configuration).to receive(:http_backtrace_depth).and_return(nil)
      result = described_class.extract_backtrace
      expect(result).to all(be_a(String))
      expect(result).not_to be_empty
    end

    it "excludes net/http and profiler/instrumentation frames" do
      allow(Profiler.configuration).to receive(:http_backtrace_depth).and_return(nil)
      result = described_class.extract_backtrace
      expect(result).to all(satisfy { |f| !f.include?("net/http") && !f.include?("profiler/instrumentation") })
    end
  end
end
