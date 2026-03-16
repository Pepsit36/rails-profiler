# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::RequestCollector do
  let(:profile) do
    build_profile(
      path: "/users",
      method: "POST",
      status: 201,
      duration: 85.5,
      params: { "name" => "alice" },
      headers: { "Accept" => "application/json" }
    )
  end

  subject(:collector) { described_class.new(profile) }

  before { profile.finish(201, { "Content-Type" => "application/json" }) }

  describe "#collect" do
    before { collector.collect }

    it "stores path in panel_content" do
      expect(collector.panel_content[:path]).to eq("/users")
    end

    it "stores method in panel_content" do
      expect(collector.panel_content[:method]).to eq("POST")
    end

    it "stores status in panel_content" do
      expect(collector.panel_content[:status]).to eq(201)
    end

    it "stores params in panel_content" do
      expect(collector.panel_content[:params]).to include("name" => "alice")
    end
  end

  describe "#toolbar_summary" do
    it "returns green color for 2xx status" do
      profile.instance_variable_set(:@status, 200)
      expect(collector.toolbar_summary[:color]).to eq("green")
    end

    it "returns blue color for 3xx status" do
      profile.instance_variable_set(:@status, 301)
      expect(collector.toolbar_summary[:color]).to eq("blue")
    end

    it "returns orange color for 4xx status" do
      profile.instance_variable_set(:@status, 404)
      expect(collector.toolbar_summary[:color]).to eq("orange")
    end

    it "returns red color for 5xx status" do
      profile.instance_variable_set(:@status, 500)
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "includes method and status in text" do
      profile.instance_variable_set(:@method, "GET")
      profile.instance_variable_set(:@status, 200)
      expect(collector.toolbar_summary[:text]).to eq("GET 200")
    end
  end
end
