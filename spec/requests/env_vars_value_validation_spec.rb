# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"

# Structured values (arrays, objects) are refused with 422; nil, strings and JSON scalars are accepted.
RSpec.describe "Environment variable value validation", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:writing) { local.merge("HTTP_X_PROFILER_REQUEST" => "1") }
  let(:tmp_dir) { Dir.mktmpdir }

  def app
    Rails.application
  end

  around do |example|
    saved = ENV.fetch("TEST_VALUE_PARAM", nil)
    example.run
  ensure
    saved.nil? ? ENV.delete("TEST_VALUE_PARAM") : ENV["TEST_VALUE_PARAM"] = saved
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      config.tmp_path = Pathname.new(tmp_dir)
    end
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  context "with valid value parameters" do
    it "accepts nil as a value" do
      patch "/_profiler/api/env_vars", { key: "TEST_VALUE_PARAM", value: nil }, writing
      expect(last_response.status).to eq(200)
      response_data = JSON.parse(last_response.body)
      expect(response_data["deleted"]).to eq(true)
    end

    it "accepts a string value" do
      patch "/_profiler/api/env_vars", { key: "TEST_VALUE_PARAM", value: "string_value" }, writing
      expect(last_response.status).to eq(200)
      response_data = JSON.parse(last_response.body)
      expect(response_data["key"]).to eq("TEST_VALUE_PARAM")
    end

    it "accepts empty string as a value" do
      patch "/_profiler/api/env_vars", { key: "TEST_VALUE_PARAM", value: "" }, writing
      expect(last_response.status).to eq(200)
      response_data = JSON.parse(last_response.body)
      expect(response_data["deleted"]).to eq(true)
    end

    it "accepts a value with special characters" do
      patch "/_profiler/api/env_vars", { key: "TEST_VALUE_PARAM", value: "value!@#$%^&*()" }, writing
      expect(last_response.status).to eq(200)
    end

    it "accepts a numeric string value" do
      patch "/_profiler/api/env_vars", { key: "TEST_VALUE_PARAM", value: "12345" }, writing
      expect(last_response.status).to eq(200)
    end
  end

  # Form encoding turns every value into a String, so typed values are sent as a JSON body.
  def patch_json(body)
    patch "/_profiler/api/env_vars", body.to_json, writing.merge("CONTENT_TYPE" => "application/json")
  end

  context "with JSON scalar values" do
    {
      "an integer" => [123, "123"],
      "a float" => [123.45, "123.45"],
      "true" => [true, "true"],
      "false" => [false, "false"]
    }.each do |label, (sent, stored)|
      it "still coerces #{label} to its string form" do
        patch_json({ key: "TEST_VALUE_PARAM", value: sent })
        expect(last_response.status).to eq(200)
        expect(ENV.fetch("TEST_VALUE_PARAM", nil)).to eq(stored)
      end
    end
  end

  context "with structured value parameters" do
    it "rejects an array value and leaves ENV unchanged" do
      patch_json({ key: "TEST_VALUE_PARAM", value: ["a", "b"] })
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to match(/must be a scalar/i)
      expect(ENV.key?("TEST_VALUE_PARAM")).to eq(false)
    end

    it "rejects a hash value and leaves ENV unchanged" do
      patch_json({ key: "TEST_VALUE_PARAM", value: { key: "value" } })
      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to match(/must be a scalar/i)
      expect(ENV.key?("TEST_VALUE_PARAM")).to eq(false)
    end
  end
end
