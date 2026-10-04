# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"

# SEC-03 through the real controller stack: what the env_vars and explain
# endpoints expose once sensitive data is masked.
RSpec.describe "Sensitive data through the profiler API", type: :request do
  include Rack::Test::Methods

  let(:mask) { Profiler::Redaction::MASK }
  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:writing) { local.merge("HTTP_X_PROFILER_REQUEST" => "1") }
  let(:storage) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  around do |example|
    saved = ENV.to_h.slice("PROFILER_SPEC_UNLISTED", "PROFILER_SPEC_TOKEN")
    ENV["PROFILER_SPEC_UNLISTED"] = "planted-unlisted-1111"
    ENV["PROFILER_SPEC_TOKEN"] = "planted-token-2222"
    example.run
  ensure
    %w[PROFILER_SPEC_UNLISTED PROFILER_SPEC_TOKEN].each { |k| saved.key?(k) ? ENV[k] = saved[k] : ENV.delete(k) }
    Profiler.env_override_store.clear
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      # Listed, but its name matches the filter (:token): still masked.
      config.env_allowlist += ["PROFILER_SPEC_TOKEN"]
    end
    Profiler.instance_variable_set(:@storage, storage)
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  describe "GET /_profiler/api/env_vars" do
    it "lists every name and masks the values outside the allowlist" do
      get "/_profiler/api/env_vars", {}, local

      expect(last_response.status).to eq(200)
      expect(json["variables"]).to include("PROFILER_SPEC_UNLISTED" => mask, "RAILS_ENV" => "test")
      expect(json["total"]).to eq(ENV.size)
    end

    it "masks a listed variable whose name matches the filter" do
      get "/_profiler/api/env_vars", {}, local

      expect(json["variables"]["PROFILER_SPEC_TOKEN"]).to eq(mask)
    end

    it "masks the current and original values of an override" do
      Profiler.env_override_store.set("PROFILER_SPEC_UNLISTED", "planted-override-3333")
      get "/_profiler/api/env_vars", {}, local

      expect(json["overrides"]["PROFILER_SPEC_UNLISTED"]).to eq("value" => mask, "original" => mask)
      expect(last_response.body).not_to include("planted")
    end
  end

  describe "PATCH /_profiler/api/env_vars" do
    it "applies the value and answers with it masked" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_UNLISTED", value: "planted-new-4444" }, writing

      expect(last_response.status).to eq(200)
      expect(json["value"]).to eq(mask)
      expect(last_response.body).not_to include("planted")
      expect(ENV["PROFILER_SPEC_UNLISTED"]).to eq("planted-new-4444")
    end

    it "refuses the mask as a value with 422, leaving ENV and the overrides alone" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_UNLISTED", value: " #{mask} " }, writing

      expect(last_response.status).to eq(422)
      expect(json["error"]).to include(mask)
      expect(ENV["PROFILER_SPEC_UNLISTED"]).to eq("planted-unlisted-1111")
      expect(Profiler.env_override_store.all_overrides).to be_empty
    end
  end

  describe "DELETE /_profiler/api/env_vars/reset" do
    it "restores the original value and answers with it masked" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_UNLISTED", value: "x" }, writing
      delete "/_profiler/api/env_vars/reset?key=PROFILER_SPEC_UNLISTED", {}, writing

      expect(last_response.status).to eq(200)
      expect(json).to include("key" => "PROFILER_SPEC_UNLISTED", "value" => mask, "reset" => true)
      expect(ENV["PROFILER_SPEC_UNLISTED"]).to eq("planted-unlisted-1111")
    end
  end

  describe "DELETE /_profiler/api/env_vars/reset_all" do
    it "restores every original value without exposing any" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_UNLISTED", value: "x" }, writing
      delete "/_profiler/api/env_vars/reset_all", {}, writing

      expect(last_response.status).to eq(200)
      expect(json).to eq("reset" => true)
      expect(ENV["PROFILER_SPEC_UNLISTED"]).to eq("planted-unlisted-1111")
    end
  end

  describe "with the previous behaviour restored" do
    before do
      Profiler.configure do |config|
        config.redact_sensitive_data = false
        config.env_allowlist = :all
      end
    end

    it "shows every value in clear" do
      get "/_profiler/api/env_vars", {}, local

      expect(json["variables"]).to include("PROFILER_SPEC_UNLISTED" => "planted-unlisted-1111",
                                           "PROFILER_SPEC_TOKEN" => "planted-token-2222")
    end

    it "answers an update and a reset with the values in clear" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_UNLISTED", value: "planted-new-4444" }, writing
      expect(json["value"]).to eq("planted-new-4444")

      delete "/_profiler/api/env_vars/reset?key=PROFILER_SPEC_UNLISTED", {}, writing
      expect(json["value"]).to eq("planted-unlisted-1111")
    end
  end

  describe "POST /_profiler/api/explain" do
    it "answers 422 for a query whose binds were masked" do
      profile = build_profile(collectors_data: {
        "database" => { "queries" => [{ "sql" => "SELECT * FROM users WHERE password_digest = ?", "binds" => [mask] }] }
      })
      storage.save(profile.token, profile)
      post "/_profiler/api/explain", { token: profile.token, query_index: 0 }, writing

      expect(last_response.status).to eq(422)
      expect(json["error"]).to match(/EXPLAIN refused for query 0/)
    end
  end
end
