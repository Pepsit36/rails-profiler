# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Models::Profile do
  let(:mock_request) do
    double(
      "request",
      path: "/users/1",
      request_method: "GET",
      params: { "name" => "alice", "token" => "secret123" },
      env: {
        "HTTP_ACCEPT" => "text/html",
        "HTTP_USER_AGENT" => "TestBrowser/1.0",
        "HTTP_X_CUSTOM" => "ignored",
        "CONTENT_TYPE" => "application/json"
      }
    )
  end

  describe "#initialize" do
    context "with a request object" do
      subject(:profile) { described_class.new(mock_request) }

      it "sets the path from the request" do
        expect(profile.path).to eq("/users/1")
      end

      it "sets the method from the request" do
        expect(profile.method).to eq("GET")
      end

      it "generates a token" do
        expect(profile.token).to match(/\A[0-9a-f]{32}\z/)
      end

      it "sets started_at" do
        expect(profile.started_at).to be_a(Time)
      end

      it "initializes collectors_data as empty hash" do
        expect(profile.collectors_data).to eq({})
      end

      it "initializes collectors_metadata as empty array" do
        expect(profile.collectors_metadata).to eq([])
      end

      it "sanitizes params by masking sensitive values" do
        expect(profile.params).to eq("name" => "alice", "token" => "[FILTERED]")
      end

      it "extracts only allowed HTTP headers" do
        expect(profile.headers).to include("Accept" => "text/html", "User-Agent" => "TestBrowser/1.0")
        expect(profile.headers).not_to have_key("X-Custom")
      end
    end

    context "without a request" do
      subject(:profile) { described_class.new }

      it "does not set path" do
        expect(profile.path).to be_nil
      end

      it "does not set method" do
        expect(profile.method).to be_nil
      end
    end
  end

  describe "#finish" do
    subject(:profile) { described_class.new }

    before { profile.finish(200, { "Content-Type" => "text/html" }) }

    it "sets status" do
      expect(profile.status).to eq(200)
    end

    it "sets finished_at" do
      expect(profile.finished_at).to be_a(Time)
    end

    it "sets duration in milliseconds" do
      expect(profile.duration).to be >= 0
    end

    it "sets response_headers" do
      expect(profile.response_headers).to eq("Content-Type" => "text/html")
    end
  end

  describe "#add_collector_data / #collector_data" do
    subject(:profile) { described_class.new }

    it "stores and retrieves data by name" do
      profile.add_collector_data("database", { total: 5 })
      expect(profile.collector_data("database")).to eq({ total: 5 })
    end

    it "converts name to string" do
      profile.add_collector_data(:request, { path: "/test" })
      expect(profile.collector_data("request")).to eq({ path: "/test" })
    end
  end

  describe "#add_collector_metadata" do
    subject(:profile) { described_class.new }

    let(:collector) do
      double(
        "collector",
        tab_config: {
          key: "database",
          label: "Database",
          icon: "🗄️",
          priority: 20,
          enabled: true,
          default_active: true
        },
        render_mode: :auto,
        has_data?: true
      )
    end

    it "appends metadata entry" do
      profile.add_collector_metadata(collector)
      expect(profile.collectors_metadata.size).to eq(1)
      meta = profile.collectors_metadata.first
      expect(meta[:key]).to eq("database")
      expect(meta[:has_data]).to eq(true)
      expect(meta[:render_mode]).to eq("auto")
    end
  end

  describe "#to_h" do
    subject(:profile) { described_class.new(mock_request) }

    before { profile.finish(200, {}) }

    it "includes all expected keys" do
      hash = profile.to_h
      expect(hash).to include(:token, :path, :method, :status, :duration,
                              :started_at, :finished_at, :params, :headers,
                              :collectors_data, :tabs, :parent_token, :is_ajax,
                              :profile_type)
    end

    it "serializes started_at as iso8601 string" do
      expect(profile.to_h[:started_at]).to match(/\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe "#to_json" do
    subject(:profile) { described_class.new(mock_request) }

    it "returns valid JSON" do
      json = profile.to_json
      expect { JSON.parse(json) }.not_to raise_error
    end
  end

  describe ".from_json / .from_hash round-trip" do
    subject(:original) { described_class.new(mock_request) }

    before do
      original.finish(404, {})
      original.add_collector_data("database", { total_queries: 3 })
    end

    it "restores token" do
      restored = described_class.from_json(original.to_json)
      expect(restored.token).to eq(original.token)
    end

    it "restores path" do
      restored = described_class.from_json(original.to_json)
      expect(restored.path).to eq("/users/1")
    end

    it "restores collectors_data with string keys" do
      restored = described_class.from_json(original.to_json)
      expect(restored.collectors_data).to have_key("database")
      expect(restored.collectors_data["database"]).to include("total_queries" => 3)
    end

    it "restores status" do
      restored = described_class.from_json(original.to_json)
      expect(restored.status).to eq(404)
    end
  end

  describe "sanitize_params" do
    it "masks password" do
      request = double("req", path: "/", request_method: "POST",
                       params: { "username" => "bob", "password" => "secret" },
                       env: {})
      profile = described_class.new(request)
      expect(profile.params["password"]).to eq("[FILTERED]")
      expect(profile.params["username"]).to eq("bob")
    end

    it "masks password_confirmation" do
      request = double("req", path: "/", request_method: "POST",
                       params: { "password_confirmation" => "x" }, env: {})
      profile = described_class.new(request)
      expect(profile.params["password_confirmation"]).to eq("[FILTERED]")
    end

    it "masks secret" do
      request = double("req", path: "/", request_method: "POST",
                       params: { "secret" => "x" }, env: {})
      profile = described_class.new(request)
      expect(profile.params["secret"]).to eq("[FILTERED]")
    end
  end

  describe "#profile_type" do
    it "defaults to 'http' for a request profile" do
      profile = described_class.new(mock_request)
      expect(profile.profile_type).to eq("http")
    end

    it "defaults to 'http' when created without a request" do
      expect(described_class.new.profile_type).to eq("http")
    end

    it "can be set to 'job'" do
      profile = described_class.new
      profile.profile_type = "job"
      expect(profile.profile_type).to eq("job")
    end

    it "is included in to_h" do
      profile = described_class.new
      profile.profile_type = "job"
      expect(profile.to_h[:profile_type]).to eq("job")
    end

    it "round-trips through from_json" do
      profile = described_class.new
      profile.profile_type = "job"
      profile.finish(200)
      restored = described_class.from_json(profile.to_json)
      expect(restored.profile_type).to eq("job")
    end

    it "falls back to 'http' when absent from JSON (backward compat)" do
      json = { token: SecureRandom.hex(16), path: "/", method: "GET" }.to_json
      profile = described_class.from_json(json)
      expect(profile.profile_type).to eq("http")
    end
  end

  describe "extract_headers" do
    it "only picks allowed headers" do
      request = double("req", path: "/", request_method: "GET", params: {},
                       env: {
                         "HTTP_ACCEPT" => "application/json",
                         "HTTP_REFERER" => "https://example.com",
                         "HTTP_X_SECRET_KEY" => "should-be-excluded"
                       })
      profile = described_class.new(request)
      expect(profile.headers).to include("Accept", "Referer")
      expect(profile.headers).not_to have_key("X-Secret-Key")
    end
  end
end
