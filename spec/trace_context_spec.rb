# frozen_string_literal: true

require "spec_helper"
require "profiler/trace_context"

RSpec.describe Profiler::TraceContext do
  let(:trace_id) { "0af7651916cd43dd8448eb211c80319c" }
  let(:parent_id) { "b7ad6b7169203331" }

  describe ".parse" do
    it "reads a valid version 00 header" do
      parsed = described_class.parse("00-#{trace_id}-#{parent_id}-01")

      expect(parsed.trace_id).to eq(trace_id)
      expect(parsed.parent_id).to eq(parent_id)
      expect(parsed.flags).to eq("01")
    end

    it "lower-cases the ids" do
      expect(described_class.parse("00-#{trace_id.upcase}-#{parent_id.upcase}-00").trace_id).to eq(trace_id)
    end

    it "reads the first four fields of a later version" do
      expect(described_class.parse("01-#{trace_id}-#{parent_id}-01-extra").trace_id).to eq(trace_id)
    end

    [
      nil, "", "garbage",
      "00-short-b7ad6b7169203331-01",
      "00-0af7651916cd43dd8448eb211c80319c-short-01",
      "00-00000000000000000000000000000000-b7ad6b7169203331-01",
      "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01",
      "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
      "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01-extra",
      "00-0af7651916cd43dd8448eb211c80319z-b7ad6b7169203331-01"
    ].each do |value|
      it "refuses #{value.inspect}" do
        expect(described_class.parse(value)).to be_nil
      end
    end
  end

  it "formats a header" do
    expect(described_class.format(trace_id, parent_id)).to eq("00-#{trace_id}-#{parent_id}-01")
  end
end
