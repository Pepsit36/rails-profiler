# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Models::TimelineEvent do
  let(:started_at) { Time.now }
  let(:finished_at) { started_at + 0.150 } # 150ms

  subject(:event) do
    described_class.new(
      name: "process_action",
      started_at: started_at,
      finished_at: finished_at,
      payload: { controller: "UsersController", action: "show" }
    )
  end

  describe "#duration" do
    it "computes duration in milliseconds" do
      expect(event.duration).to be_within(0.1).of(150.0)
    end
  end

  describe "#children" do
    it "starts with no children" do
      expect(event.children).to be_empty
    end
  end

  describe "#add_child" do
    let(:child_event) do
      described_class.new(
        name: "render_template",
        started_at: started_at + 0.010,
        finished_at: started_at + 0.050
      )
    end

    it "appends to children" do
      event.add_child(child_event)
      expect(event.children).to include(child_event)
    end

    it "supports multiple children" do
      event.add_child(child_event)
      another = described_class.new(
        name: "render_partial",
        started_at: started_at + 0.060,
        finished_at: started_at + 0.090
      )
      event.add_child(another)
      expect(event.children.size).to eq(2)
    end
  end

  describe "#to_h" do
    it "includes name, duration, payload, and children" do
      hash = event.to_h
      expect(hash).to include(:name, :duration, :payload, :children, :started_at, :finished_at)
    end

    it "serializes children recursively" do
      child = described_class.new(
        name: "render_partial",
        started_at: started_at + 0.010,
        finished_at: started_at + 0.040
      )
      event.add_child(child)
      expect(event.to_h[:children].first[:name]).to eq("render_partial")
    end
  end

  describe "#to_json" do
    it "returns valid JSON" do
      expect { JSON.parse(event.to_json) }.not_to raise_error
    end
  end
end
