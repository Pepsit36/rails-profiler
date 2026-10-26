# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# Validate that filter and limit parameters are properly typed and do not cause 500 errors.
RSpec.describe "Profile filtering with validation", type: :request do
  include Rack::Test::Methods

  let(:headers) do
    { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost", "HTTP_X_PROFILER_REQUEST" => "1" }
  end
  let(:store) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  before do
    Profiler.configure { |config| config.enabled = true }
    Profiler.instance_variable_set(:@storage, store)
    # Create test profiles
    store.save("11111111111111111111111111111111", build_profile(token: "11111111111111111111111111111111", path: "/api/users", method: "GET", duration: 0.5))
    store.save("22222222222222222222222222222222", build_profile(token: "22222222222222222222222222222222", path: "/api/posts", method: "POST", duration: 1.5))
    store.save("33333333333333333333333333333333", build_profile(token: "33333333333333333333333333333333", path: "/api/users/123", method: "GET", duration: 0.2))
  end

  after { Profiler.instance_variable_set(:@storage, nil) }

  def listed_paths
    controller = last_request.env["action_controller.instance"]
    controller.instance_variable_get(:@profiles).map(&:path).sort
  end

  context "with valid filter parameters" do
    it "filters profiles by path" do
      get "/_profiler/profiles", { filter: { path: "/api/users" } }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths).to eq(["/api/users", "/api/users/123"])
    end

    it "filters profiles by method" do
      get "/_profiler/profiles", { filter: { method: "POST" } }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths).to eq(["/api/posts"])
    end

    it "filters profiles by minimum duration" do
      get "/_profiler/profiles", { filter: { min_duration: "1" } }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths).to eq(["/api/posts"])
    end

    it "combines several filter criteria" do
      get "/_profiler/profiles", { filter: { path: "/api", method: "GET", min_duration: "0.3" } }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths).to eq(["/api/users"])
    end

    it "lists everything without a filter" do
      get "/_profiler/profiles", {}, headers
      expect(listed_paths).to eq(["/api/posts", "/api/users", "/api/users/123"])
    end
  end

  context "with invalid filter parameters" do
    it "returns 422 when filter is a string instead of a hash" do
      get "/_profiler/profiles", { filter: "invalid_string" }, headers
      expect(last_response.status).to eq(422)
      response_data = JSON.parse(last_response.body)
      expect(response_data["error"]).to match(/filter must be a hash/i)
    end

    it "returns 422 when filter is an integer" do
      get "/_profiler/profiles", { filter: 123 }, headers
      expect(last_response.status).to eq(422)
    end

    it "returns 422 when filter is an array" do
      get "/_profiler/profiles", { filter: ["path", "value"] }, headers
      expect(last_response.status).to eq(422)
    end
  end

  context "with invalid limit and offset parameters" do
    it "treats a non-numeric limit as zero" do
      get "/_profiler/profiles", { limit: "not_a_number" }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths).to eq([])
    end

    it "clamps a negative limit to an empty list instead of raising" do
      get "/_profiler/profiles", { limit: "-5" }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths).to eq([])
    end

    it "clamps a negative offset to zero" do
      get "/_profiler/profiles", { offset: "-5" }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths.size).to eq(3)
    end

    it "accepts a very large limit" do
      get "/_profiler/profiles", { limit: "999999" }, headers
      expect(last_response.status).to eq(200)
      expect(listed_paths.size).to eq(3)
    end
  end
end
