# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "tmpdir"
require "pathname"
require "profiler/collectors/database_collector"
require "profiler/collectors/mailer_collector"
require "profiler/instrumentation/net_http_instrumentation"
require "profiler/mcp/tools/set_env_var"

# Regression specs for SEC-03, from the second review of the fix.
RSpec.describe "Sensitive data redaction, second review follow-up" do
  include Rack::Test::Methods

  let(:mask) { Profiler::Redaction::MASK }

  def fake_rails(filters, logger: nil)
    config = Struct.new(:filter_parameters).new(filters)
    app = Struct.new(:config).new(config)
    Struct.new(:application, :logger).new(app, logger)
  end

  describe "bodies read as binary (rack.input, Net::HTTP)" do
    it "keeps a clean JSON body with accented text" do
      raw = '{"user":{"name":"René"}}'.b
      expect(Profiler::Redaction.filter_body(raw, "application/json").force_encoding("UTF-8"))
        .to eq('{"user":{"name":"René"}}')
    end

    it "masks a filtered key of a JSON body with accented text" do
      raw = '{"city":"Orléans","password":"Orléans-1"}'.b
      expect(JSON.parse(Profiler::Redaction.filter_body(raw, "application/json")))
        .to eq("city" => "Orléans", "password" => mask)
    end

    it "filters binary form, NDJSON and invalid UTF-8 bodies without masking them entirely" do
      form = "name=Ren\xC3\xA9&password=x&raw=\xFF".b
      expect(Profiler::Redaction.filter_body(form, "application/x-www-form-urlencoded").b)
        .to eq("name=Ren\xC3\xA9&password=#{mask}&raw=\xFF".b)

      ndjson = %({"name":"René"}\n{"token":"t"}\n).b
      expect(Profiler::Redaction.filter_body(ndjson, "application/x-ndjson"))
        .to eq(%({"name":"René"}\n{"token":"#{mask}"}\n))

      invalid = %({"password":"\xFF"}).b
      expect(Profiler::Redaction.filter_body(invalid, "application/json")).not_to include("\xFF".b)
    end

    it "keeps an accented outbound JSON body" do
      processed = Profiler::Instrumentation::NetHttpInstrumentation.process_body('{"city":"Orléans"}'.b, "application/json")
      expect(processed[:body]).to eq('{"city":"Orléans"}')
    end

    it "keeps an accented body stored through the middleware" do
      Profiler.configure do |c|
        c.enabled = true
        c.collectors = []
        c.skip_paths = []
        c.track_memory = false
        c.track_http = false
      end
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      app = Profiler::Middleware::ProfilerMiddleware.new(->(_env) { [200, { "Content-Type" => "text/plain" }, ["ok"]] })
      # A request from this machine, as the default :allow_local expects.
      env = Rack::MockRequest.env_for("http://localhost/users", method: "POST", input: '{"user":{"name":"René"}}'.b,
                                                                "REMOTE_ADDR" => "127.0.0.1",
                                                                "CONTENT_TYPE" => "application/json")
      app.call(env)

      expect(Profiler.storage.list.first.request_body).to eq('{"user":{"name":"René"}}')
    end
  end

  describe "a failing filter" do
    it "is reported once per error class, without the value" do
      logger = double("logger")
      stub_const("Rails", fake_rails([->(_k, _v) { raise ArgumentError, "planted-proc-message" }], logger: logger))
      expect(logger).to receive(:warn).once.with(satisfy { |m| m.include?("ArgumentError") && !m.include?("planted") })

      Profiler::Redaction.filter_hash("a" => "planted-1")
      Profiler::Redaction.filter_hash("b" => "planted-2")
    end
  end

  describe "a proc in filter_parameters applied to named values" do
    # Partial masking of card numbers, as a PCI-minded application writes it.
    let(:pci) do
      ->(key, value) { value.replace("****#{value[-4..]}") if key.to_s =~ /card[-_]?number/i && value.is_a?(String) }
    end

    before { stub_const("Rails", fake_rails([:password, pci])) }

    it "rewrites a SQL bind" do
      profile = build_profile
      collector = Profiler::Collectors::DatabaseCollector.new(profile)
      collector.subscribe
      bind = Struct.new(:name, :value)
      ActiveSupport::Notifications.instrument("sql.active_record",
        sql: "INSERT INTO cards (card_number, owner) VALUES (?, ?)", name: "Card Create",
        binds: [bind.new("card_number", "4111111111111111"), bind.new("owner", "Alice")])
      collector.collect

      expect(profile.collector_data("database")[:queries].first[:binds]).to eq(["****1111", "Alice"])
    end

    it "rewrites a header" do
      expect(Profiler::Redaction.filter_headers("Card-Number" => "4111111111111111", "Accept" => "*/*"))
        .to eq("Card-Number" => "****1111", "Accept" => "*/*")
    end

    it "rewrites an allowlisted ENV value" do
      Profiler.configuration.env_allowlist = ["CARD_NUMBER"]
      expect(Profiler::Redaction.env_snapshot("CARD_NUMBER" => "4111111111111111")).to eq("CARD_NUMBER" => "****1111")
    end

    it "rewrites a named mailer argument" do
      expect(Profiler::Redaction.filter_named("card_number", "4111111111111111")).to eq("****1111")
    end
  end

  describe "JSON the parser cannot read" do
    it "masks it entirely when it holds a filtered key" do
      ['{password: "X"}', "{'password': 'X'}", %({"a": 1, password: "X"})].each do |raw|
        expect(Profiler::Redaction.filter_body(raw, "application/json")).to start_with("[FILTERED: unparseable")
      end
    end
  end

  describe "the mask as a value" do
    it "is refused by set_env_var even with surrounding spaces" do
      dir = Dir.mktmpdir
      Profiler.configuration.tmp_path = Pathname(dir)
      Profiler.instance_variable_set(:@env_override_store, nil)
      text = Profiler::MCP::Tools::SetEnvVar.call("key" => "PROFILER_SPEC_X", "value" => " #{mask} ").first[:text]

      expect(text).to start_with("Error:")
      expect(ENV["PROFILER_SPEC_X"]).to be_nil
    ensure
      ENV.delete("PROFILER_SPEC_X")
      Profiler.instance_variable_set(:@env_override_store, nil)
      FileUtils.rm_rf(dir)
    end
  end

  describe "URL headers as Rack 3 arrays" do
    it "filters each value" do
      expect(Profiler::Redaction.filter_headers("location" => ["/a?token=t", "/b"]))
        .to eq("location" => ["/a?token=#{mask}", "/b"])
    end
  end
end
