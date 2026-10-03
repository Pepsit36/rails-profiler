# frozen_string_literal: true

require "spec_helper"
require "profiler/explain_runner"
require "profiler/env_override_store"

RSpec.describe Profiler::Redaction do
  let(:mask) { described_class::MASK }

  describe "filter sources" do
    it "falls back to the gem's own list when Rails is not loaded" do
      hide_const("Rails")
      expect(described_class.filter_hash("password" => "x", "api_key" => "y", "name" => "z"))
        .to eq("password" => mask, "api_key" => mask, "name" => "z")
    end

    it "adds the application's filter_parameters to the gem's list" do
      config = Struct.new(:filter_parameters).new([:iban])
      stub_const("Rails", Struct.new(:application).new(Struct.new(:config).new(config)))

      expect(described_class.filter_hash("iban" => "FR76", "password" => "x", "name" => "z"))
        .to eq("iban" => mask, "password" => mask, "name" => "z")
    end

    it "picks up filters added after the first use" do
      hide_const("Rails")
      expect(described_class.filter_hash("iban" => "FR76")).to eq("iban" => "FR76")

      Profiler.configuration.filter_parameters += [:iban]
      expect(described_class.filter_hash("iban" => "FR76")).to eq("iban" => mask)
    end

    it "masks nothing from the gem's list once config.filter_parameters is emptied" do
      hide_const("Rails")
      Profiler.configuration.filter_parameters = []
      expect(described_class.filter_hash("password" => "x")).to eq("password" => "x")
    end
  end

  describe ".filter_headers" do
    it "masks dashed header names that match an underscored filter" do
      expect(described_class.filter_headers("X-Api-Key" => "k", "Proxy-Authorization" => "p", "Accept" => "*/*"))
        .to eq("X-Api-Key" => mask, "Proxy-Authorization" => mask, "Accept" => "*/*")
    end
  end

  describe ".filter_body" do
    it "masks keys inside a top-level JSON array and keeps an untouched body byte for byte" do
      expect(JSON.parse(described_class.filter_body('[{"token":"t","id":1}]', "application/json")))
        .to eq([{ "token" => mask, "id" => 1 }])

      raw = "{ \"id\" : 1 }"
      expect(described_class.filter_body(raw, "application/vnd.api+json")).to equal(raw)
    end

    it "keeps HTML and other unstructured text bodies as they are" do
      html = "<input name=password value=secret>"
      expect(described_class.filter_body(html, "text/html")).to eq(html)
    end

    it "masks a form pair Rack cannot parse rather than trusting it" do
      allow(Rack::Utils).to receive(:parse_nested_query).and_raise(Rack::Utils::ParameterTypeError)
      expect(described_class.filter_body("a=1", "application/x-www-form-urlencoded")).to eq("a=#{mask}")
    end
  end

  describe ".filter_url" do
    it "leaves a URL without query string unchanged" do
      expect(described_class.filter_url("https://api.example.com/v1/users")).to eq("https://api.example.com/v1/users")
    end
  end

  describe "ENV" do
    it "masks an allowlisted variable whose name matches the filter" do
      Profiler.configuration.env_allowlist = ["MY_SECRET"]
      expect(described_class.env_snapshot("MY_SECRET" => "s", "OTHER" => "o"))
        .to eq("MY_SECRET" => mask, "OTHER" => mask)
    end

    it "accepts regexps in the allowlist" do
      Profiler.configuration.env_allowlist = [/\AAPP_/]
      expect(described_class.env_snapshot("APP_NAME" => "demo", "OTHER" => "o"))
        .to eq("APP_NAME" => "demo", "OTHER" => mask)
    end

    it "shows every value with env_allowlist = :all, except filtered names" do
      Profiler.configuration.env_allowlist = :all
      expect(described_class.env_snapshot("OTHER" => "o", "DB_PASSWORD" => "p"))
        .to eq("DB_PASSWORD" => mask, "OTHER" => "o")
    end

    it "masks the values of overrides on variables outside the allowlist, keeping the deleted marker" do
      overrides = {
        "STRIPE_KEY" => { "value" => "sk_live", "original" => "sk_test" },
        "GONE" => { "value" => Profiler::EnvOverrideStore::DELETED_SENTINEL, "original" => nil },
        "RAILS_ENV" => { "value" => "staging", "original" => "development" }
      }
      expect(described_class.env_overrides(overrides)).to eq(
        "STRIPE_KEY" => { "value" => mask, "original" => mask },
        "GONE" => { "value" => Profiler::EnvOverrideStore::DELETED_SENTINEL, "original" => nil },
        "RAILS_ENV" => { "value" => "staging", "original" => "development" }
      )
    end
  end

  describe "opting out" do
    it "restores the previous behaviour with redact_sensitive_data = false and env_allowlist = :all" do
      hide_const("Rails")
      Profiler.configure do |c|
        c.redact_sensitive_data = false
        c.env_allowlist = :all
      end

      expect(described_class.filter_headers("Authorization" => "Bearer x")).to eq("Authorization" => "Bearer x")
      expect(described_class.filter_body('{"password":"x"}', "application/json")).to eq('{"password":"x"}')
      expect(described_class.filter_url("http://h/p?api_key=1")).to eq("http://h/p?api_key=1")
      expect(described_class.env_snapshot("DB_PASSWORD" => "p")).to eq("DB_PASSWORD" => "p")

      request = Rack::Request.new(Rack::MockRequest.env_for("/?password=a&api_key=b&PASSWORD=c"))
      expect(Profiler::Models::Profile.new(request).params).to eq("api_key" => "b", "PASSWORD" => "c")
    end
  end

  describe "EXPLAIN on a query whose binds were filtered" do
    it "refuses with a clear message instead of running a rewritten query" do
      Profiler.configure { |c| c.enabled = true }
      store = Profiler::Storage::MemoryStore.new
      Profiler.instance_variable_set(:@storage, store)
      profile = build_profile(collectors_data: {
        "database" => { "queries" => [{ "sql" => "SELECT * FROM users WHERE password_digest = ?",
                                        "binds" => [mask] }] }
      })
      store.save(profile.token, profile)
      base = double("ActiveRecord::Base")
      stub_const("ActiveRecord::Base", base)
      expect(base).not_to receive(:connection)

      expect { Profiler::ExplainRunner.run(profile.token, 0) }
        .to raise_error(ArgumentError, /EXPLAIN refused for query 0: .*filtered/)
    end
  end
end
