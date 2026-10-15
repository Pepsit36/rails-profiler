# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "pathname"
require "profiler/collectors/database_collector"
require "profiler/collectors/env_collector"
require "profiler/collectors/mailer_collector"
require "profiler/collectors/request_collector"
require "profiler/mcp/tools/set_env_var"
require "profiler/mcp/tools/reset_env_var"
require "profiler/mcp/tools/list_env_vars"

# Follow-up regression specs for SEC-03, from the review of the first fix.
RSpec.describe "Sensitive data redaction, review follow-up" do
  let(:mask) { Profiler::Redaction::MASK }

  def fake_rails(filters, app_extra = {})
    config = Struct.new(:filter_parameters).new(filters)
    app = Struct.new(:config, *app_extra.keys).new(config, *app_extra.values)
    Struct.new(:application, :logger).new(app, nil)
  end

  describe "a proc in filter_parameters (partial masking)" do
    # The kind of proc Rails documents: it rewrites every value in place.
    let(:partial) { ->(_key, value) { value.replace("#{value[0, 2]}***") } }

    before { stub_const("Rails", fake_rails([:password, partial])) }

    it "does not raise from the sql.active_record subscriber, and masks the bind of a filtered column" do
      profile = build_profile
      collector = Profiler::Collectors::DatabaseCollector.new(profile)
      collector.subscribe
      bind = Struct.new(:name, :value)

      expect do
        ActiveSupport::Notifications.instrument("sql.active_record",
          sql: "UPDATE users SET password = ?, name = ?", name: "User Update",
          binds: [bind.new("password", "hunter2"), bind.new("name", "Alice")])
      end.not_to raise_error
      collector.collect

      expect(profile.collector_data("database")[:queries].first[:binds].first).to eq(mask)
    end

    it "does not raise when filtering headers or ENV" do
      expect { Profiler::Redaction.filter_headers("Authorization" => "b", "Accept" => "*/*") }.not_to raise_error
      expect { Profiler::Redaction.env_snapshot("RAILS_ENV" => "test", "DB_PASSWORD" => "p") }.not_to raise_error
      expect(Profiler::Redaction.env_snapshot("DB_PASSWORD" => "p")).to eq("DB_PASSWORD" => mask)
    end

    it "fails closed when the filter itself raises" do
      stub_const("Rails", fake_rails([->(_k, _v) { raise "boom" }]))

      # Procs judge values, not names: the name passes, its value is masked.
      expect(Profiler::Redaction.filter_named("anything", "1")).to eq(mask)
      expect(Profiler::Redaction.filter_headers("X-Anything" => "1")).to eq("X-Anything" => mask)
      expect(Profiler::Redaction.filter_hash("a" => "1")).to eq("a" => mask)
      expect(Profiler::Redaction.filter_body('{"a":"1"}', "application/json")).not_to include('"1"')
    end
  end

  describe "ENV overrides through the MCP tools" do
    let(:dir) { Dir.mktmpdir }

    around do |example|
      ENV["PROFILER_SPEC_SECRET_VAR"] = "planted-original-ffff"
      example.run
    ensure
      ENV.delete("PROFILER_SPEC_SECRET_VAR")
      FileUtils.rm_rf(dir)
    end

    before do
      Profiler.configuration.tmp_path = Pathname(dir)
      Profiler.instance_variable_set(:@env_override_store, nil)
    end

    after { Profiler.instance_variable_set(:@env_override_store, nil) }

    it "does not reveal the original value on reset_env_var" do
      Profiler::MCP::Tools::SetEnvVar.call("key" => "PROFILER_SPEC_SECRET_VAR", "value" => "x")
      text = Profiler::MCP::Tools::ResetEnvVar.call("key" => "PROFILER_SPEC_SECRET_VAR").first[:text]

      expect(text).not_to include("planted-original-ffff")
      # The message says what the reset did and carries no value, masked or not.
      expect(text).not_to include(mask)
      expect(text).to eq("Reset PROFILER_SPEC_SECRET_VAR: override removed, original value restored in this process.")
    end

    it "refuses to set a variable to the mask, so a re-imported export cannot overwrite a secret" do
      text = Profiler::MCP::Tools::SetEnvVar.call("key" => "PROFILER_SPEC_SECRET_VAR", "value" => mask).first[:text]

      expect(text).to start_with("Error:")
      expect(ENV["PROFILER_SPEC_SECRET_VAR"]).to eq("planted-original-ffff")
      expect(Profiler.env_override_store.all_overrides).to be_empty
    end

    it "keeps the restore marker of an override as it keeps the deleted one" do
      overrides = { "OTHER" => { "value" => Profiler::EnvOverrideStore::RESTORE_SENTINEL, "original" => "o" } }
      expect(Profiler::Redaction.env_overrides(overrides))
        .to eq("OTHER" => { "value" => Profiler::EnvOverrideStore::RESTORE_SENTINEL, "original" => mask })
    end
  end

  describe "URLs carried by headers" do
    before { stub_const("Rails", fake_rails([:password, /token/i])) }

    it "filters the query string of an incoming Referer" do
      env = Rack::MockRequest.env_for("/", "HTTP_REFERER" => "https://app.test/users/password/edit?reset_password_token=abc&x=1")
      profile = Profiler::Models::Profile.new(Rack::Request.new(env))

      expect(profile.headers["Referer"]).to eq("https://app.test/users/password/edit?reset_password_token=#{mask}&x=1")
    end

    it "filters the query string of Location and Content-Location response headers" do
      profile = Profiler::Models::Profile.new
      profile.finish(302, "Location" => "/users/confirmation?confirmation_token=abc#top",
                          "content-location" => "/a?token=t")

      expect(profile.response_headers["Location"]).to eq("/users/confirmation?confirmation_token=#{mask}#top")
      expect(profile.response_headers["content-location"]).to eq("/a?token=#{mask}")
    end

    it "filters URL headers on outbound requests too" do
      expect(Profiler::Redaction.filter_headers("location" => "https://x.test/cb?access_token=abc"))
        .to eq("location" => "https://x.test/cb?access_token=#{mask}")
    end
  end

  describe "mailer arguments" do
    before { stub_const("Rails", fake_rails([:password, /token/i])) }

    it "masks filtered keys inside a hash argument" do
      stub_const("NotifyMailer", Class.new { def notify(user_id, options); end })
      Profiler.configure { |c| c.track_mailers = true }
      profile = build_profile
      collector = Profiler::Collectors::MailerCollector.new(profile)
      collector.subscribe
      ActiveSupport::Notifications.instrument("process.action_mailer",
        mailer: "NotifyMailer", action: "notify", args: [42, { api_token: "planted-mailer-token-1234", lang: "fr" }])
      ActiveSupport::Notifications.instrument("deliver.action_mailer",
        mailer_class: "NotifyMailer", subject: "Hi", to: ["a@b.c"], from: ["n@b.c"],
        message_id: "<m@b.c>", perform_deliveries: true, mail: nil)
      collector.collect
      options = profile.collector_data("mailer")[:emails].first["assigns"]["options"]

      expect(options).not_to include("planted-mailer-token-1234")
      expect(options).to include("fr")
    end
  end

  describe "body types" do
    it "reads text/json and x-ndjson bodies" do
      expect(JSON.parse(Profiler::Redaction.filter_body('{"password":"p"}', "text/json"))).to eq("password" => mask)

      ndjson = %({"id":1,"token":"t"}\n{"id":2}\n)
      expect(Profiler::Redaction.filter_body(ndjson, "application/x-ndjson"))
        .to eq(%({"id":1,"token":"#{mask}"}\n{"id":2}\n))
    end

    it "does not parse a JSON body in whose text no filter matches" do
      raw = JSON.generate(data: [{ id: 1, title: "a" }, { id: 2, title: "b" }])
      expect(JSON).not_to receive(:parse)

      expect(Profiler::Redaction.filter_body(raw, "application/json")).to equal(raw)
    end

    it "parses a body where a filtered word appears only in a value, and keeps it" do
      raw = JSON.generate(id: 2, title: "reset your password")
      expect(JSON).to receive(:parse).and_call_original

      expect(Profiler::Redaction.filter_body(raw, "application/json")).to equal(raw)
    end

    it "still parses when a key is written with an escape the pre-test cannot read" do
      raw = '{"password":"p"}'
      expect(JSON.parse(Profiler::Redaction.filter_body(raw, "application/json"))).to eq("password" => mask)
    end

    it "still parses when a key holds a character that case-folds onto ASCII letters" do
      raw = %({"pa\u017Fsword":"p","note":"\u00E9t\u00E9"})
      expect(JSON.parse(Profiler::Redaction.filter_body(raw, "application/json")))
        .to eq("pa\u017Fsword" => mask, "note" => "\u00E9t\u00E9")
    end

    it "still parses when a regexp filter matches a key the pre-test found" do
      stub_const("Rails", fake_rails([/\Asession_id\z/]))
      expect(JSON.parse(Profiler::Redaction.filter_body('{"session_id":"s","a":1}', "application/json")))
        .to eq("session_id" => mask, "a" => 1)
    end
  end

  describe "route params" do
    it "masks filtered route params" do
      routes = Object.new
      def routes.recognize_path(*) = { controller: "confirmations", action: "show", token: "planted-route-token" }
      def routes.named_routes = {}
      stub_const("Rails", fake_rails([/token/i], routes: routes))
      stub_const("ActiveSupport::Inflector", Module.new { def self.camelize(s) = s.capitalize })
      profile = build_profile(path: "/confirm/planted-route-token")
      Profiler::Collectors::RequestCollector.new(profile).collect

      expect(profile.collector_data("request")[:route_params]).to eq(token: mask)
    end
  end
end
