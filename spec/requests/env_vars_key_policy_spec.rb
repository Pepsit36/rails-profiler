# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/rails_app"
require "profiler/mcp/tools/set_env_var"
require "profiler/mcp/tools/delete_env_var"
require "profiler/mcp/tools/reset_env_var"

# The Env tab and the MCP env tools write ENV and the overrides file: a name ENV cannot hold
# ("A=B") or a variable that selects the database or the code a process loads is refused before
# either is written.
RSpec.describe "The names the env tools may set or delete", type: :request do
  include Rack::Test::Methods

  let(:writing) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost", "HTTP_X_PROFILER_REQUEST" => "1" } }
  let(:tmp_dir) { Dir.mktmpdir }
  let(:file) { File.join(tmp_dir, "env_overrides.json") }

  def app
    Rails.application
  end

  around do |example|
    saved = ENV.to_h
    example.run
  ensure
    ENV.replace(saved)
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

  refused = {
    "LD_PRELOAD" => "/tmp/evil.so",
    "GIT_SSH_COMMAND" => "touch /tmp/pwned",
    "DATABASE_URL" => "postgres://elsewhere/db",
    "database_url" => "postgres://elsewhere/db",
    "RUBYOPT" => "-r/tmp/evil",
    "PATH" => "/tmp",
    "A=B" => "x",
    "1ABC" => "x",
    "WITH SPACE" => "x",
    "MY-VAR" => "x",
    # Active Record reads PRIMARY_DATABASE_URL before DATABASE_URL.
    "PRIMARY_DATABASE_URL" => "postgres://elsewhere/db",
    "Analytics_Database_Url" => "postgres://elsewhere/db",
    "PGHOST" => "elsewhere",
    "PGPASSWORD" => "x",
    "MYSQL_PWD" => "x",
    "http_proxy" => "http://elsewhere:3128",
    "HTTPS_PROXY" => "http://elsewhere:3128",
    "Https_Proxy" => "http://elsewhere:3128",
    "no_proxy" => "*",
    "OPENSSL_CONF" => "/tmp/evil.cnf",
    "SSL_CERT_FILE" => "/tmp/ca.pem",
    "SSL_CERT_DIR" => "/tmp/certs",
    "RAILS_MASTER_KEY" => "x",
    "GCONV_PATH" => "/tmp",
    "ZDOTDIR" => "/tmp",
    "IRBRC" => "/tmp/evil.rb",
    "PRY_RC" => "/tmp/evil.rb",
    "PRYRC" => "/tmp/evil.rb",
    "LESSOPEN" => "|/tmp/evil %s",
    "JAVA_TOOL_OPTIONS" => "-javaagent:/tmp/evil.jar",
    "PROFILER_MCP_READ_ONLY" => "0",
    "LOCALDOMAIN" => "evil.example",
    "RES_OPTIONS" => "options debug",
    "HOSTALIASES" => "/tmp/evil",
    "NODE_EXTRA_CA_CERTS" => "/tmp/evil.pem",
    "TMPDIR" => "/tmp/evil"
  }

  describe Profiler::EnvKeyPolicy do
    it "refuses each of #{refused.keys.join(", ")}" do
      refused.each_key { |key| expect(described_class.rejection(key)).not_to be_nil, key }
    end

    it "accepts an ordinary application variable, whatever its case" do
      %w[FEATURE_FLAG_X my_app_timeout _PRIVATE DATABASE_URL_NOTE PROXY_TIMEOUT].each do |key|
        expect(described_class.rejection(key)).to be_nil, key
      end
    end

    it "refuses a value holding a NUL byte, and only that" do
      expect(described_class.value_rejection("FEATURE_FLAG_X", "on\u0000off")).to include("NUL byte")
      expect(described_class.value_rejection("FEATURE_FLAG_X", "on off")).to be_nil
      expect(described_class.value_rejection("FEATURE_FLAG_X", nil)).to be_nil
    end

    it "keeps the reserved marker's own message" do
      expect(described_class.rejection("profiler_test_runner_child")).to eq(described_class::RESERVED_KEY_ERROR)
    end

    it "is the list the test runner reads" do
      expect(Profiler::TestRunner::Runner::BLOCKED_ENV_KEYS).to equal(described_class::PROTECTED_KEYS)
      expect(Profiler::TestRunner::Runner.code_loading_env_key?("LD_PRELOAD")).to be(true)
      expect(Profiler::TestRunner::Runner.code_loading_env_key?("A=B")).to be(true)
      expect(Profiler::TestRunner::Runner.code_loading_env_key?("FEATURE_FLAG_X")).to be(false)
    end
  end

  def expect_untouched(key)
    expect(ENV.to_h).not_to have_key(key)
    expect(File).not_to exist(file)
  end

  refused.each do |key, value|
    context "with #{key.inspect}" do
      before { ENV.delete(key) unless key.include?("=") }

      it "the endpoint refuses to set it, with 422, before writing the file or ENV" do
        saved = ENV[key] unless key.include?("=")
        patch "/_profiler/api/env_vars", { key: key, value: value }, writing

        expect(last_response.status).to eq(422)
        expect(JSON.parse(last_response.body)["error"]).to include("#{key} was left unchanged")
        expect(File).not_to exist(file)
        expect(ENV[key]).to eq(saved) unless key.include?("=")
      end

      it "the endpoint refuses to delete it" do
        patch "/_profiler/api/env_vars", { key: key, value: "" }, writing

        expect(last_response.status).to eq(422)
        expect(File).not_to exist(file)
      end

      it "set_env_var refuses it as an error" do
        response = Profiler::MCP::Tools::SetEnvVar.call("key" => key, "value" => value)

        expect(response).to be_a(MCP::Tool::Response)
        expect(response.error?).to be(true)
        expect(response.content.first[:text]).to include("#{key} was left unchanged")
        expect(File).not_to exist(file)
      end

      it "delete_env_var refuses it as an error" do
        response = Profiler::MCP::Tools::DeleteEnvVar.call("key" => key)

        expect(response.error?).to be(true)
        expect(File).not_to exist(file)
      end
    end
  end

  it "refuses a key with = before asking a slave" do
    expect(Profiler::MCP::SlaveSupport).not_to receive(:with_slave_proxy)
    response = Profiler::MCP::Tools::SetEnvVar.call("key" => "A=B", "value" => "x", "slave" => "s1")
    expect(response.error?).to be(true)
  end

  # ENV[]= raises ArgumentError on a NUL byte: before, the file was written first, then the tool
  # failed with an internal error, and every apply! after it logged the same error again.
  context "with a value holding a NUL byte" do
    let(:value) { "on\u0000off" }

    before { ENV.delete("PROFILER_SPEC_NUL") }

    it "the endpoint refuses it, with 422, before writing the file or ENV" do
      patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_NUL", value: value }, writing

      expect(last_response.status).to eq(422)
      expect(JSON.parse(last_response.body)["error"]).to include("NUL byte", "PROFILER_SPEC_NUL was left unchanged")
      expect_untouched("PROFILER_SPEC_NUL")
    end

    it "set_env_var refuses it as an error, before asking a slave" do
      expect(Profiler::MCP::SlaveSupport).not_to receive(:with_slave_proxy)
      response = Profiler::MCP::Tools::SetEnvVar.call("key" => "PROFILER_SPEC_NUL", "value" => value)

      expect(response).to be_a(MCP::Tool::Response)
      expect(response.error?).to be(true)
      expect(response.content.first[:text]).to include("NUL byte", "PROFILER_SPEC_NUL was left unchanged")
      expect_untouched("PROFILER_SPEC_NUL")
    end

    it "the store refuses it before writing the file" do
      expect { Profiler.env_override_store.set("PROFILER_SPEC_NUL", value) }
        .to raise_error(Profiler::EnvOverrideStore::Error, /NUL byte/)
      expect_untouched("PROFILER_SPEC_NUL")
    end

    it "apply! leaves one already in the file out, saying so once, and applies the others" do
      File.write(file, JSON.generate("PROFILER_SPEC_NUL" => { "value" => value }, "PROFILER_SPEC_AFTER" => { "value" => "applied" }))
      store = Profiler::EnvOverrideStore.new

      log = capture_profiler_log { 3.times { store.apply! } }

      expect(ENV).not_to have_key("PROFILER_SPEC_NUL")
      expect(ENV["PROFILER_SPEC_AFTER"]).to eq("applied")
      expect(log.scan("1 persisted environment override was not applied").size).to eq(1)
      expect(log).not_to include("failed to apply")
    end
  end

  it "still sets an ordinary variable" do
    patch "/_profiler/api/env_vars", { key: "PROFILER_SPEC_ALLOWED", value: "on" }, writing

    expect(last_response.status).to eq(200)
    expect(ENV["PROFILER_SPEC_ALLOWED"]).to eq("on")
    expect(Profiler.env_override_store.all_overrides.dig("PROFILER_SPEC_ALLOWED", "value")).to eq("on")
  end

  # Written by an earlier version, which did not check the names.
  context "with refused keys already in the file" do
    let(:store) { Profiler::EnvOverrideStore.new }

    before do
      File.write(
        file,
        JSON.generate(
          # An original ENV could not take back either.
          "A=B" => { "value" => "x", "original" => "y" },
          "LD_PRELOAD" => { "value" => "/tmp/evil.so", "original" => nil },
          "PRIMARY_DATABASE_URL" => { "value" => "postgres://elsewhere/db", "original" => nil },
          "PROFILER_SPEC_AFTER" => { "value" => "applied", "original" => nil }
        )
      )
      ENV.delete("LD_PRELOAD")
      ENV.delete("PRIMARY_DATABASE_URL")
    end

    it "apply! leaves them out, applies the keys after them, and says how many it left out" do
      log = capture_profiler_log { store.apply! }

      expect(ENV["PROFILER_SPEC_AFTER"]).to eq("applied")
      expect(ENV).not_to have_key("LD_PRELOAD")
      expect(ENV).not_to have_key("PRIMARY_DATABASE_URL")
      expect(log).to include("3 persisted environment overrides were not applied")
      expect(log).not_to include("LD_PRELOAD")
      expect(log).not_to include("failed to apply")
    end

    it "apply! keeps applying the other keys when one cannot be written" do
      File.write(file, JSON.generate("PROFILER_SPEC_BAD" => { "value" => 42 }, "PROFILER_SPEC_AFTER" => { "value" => "applied" }))

      capture_profiler_log { store.apply! }
      expect(ENV["PROFILER_SPEC_AFTER"]).to eq("applied")
    end

    it "reset_env_var still takes an invalid name out, without an error" do
      Profiler.instance_variable_set(:@env_override_store, store)
      text = Profiler::MCP::Tools::ResetEnvVar.call("key" => "A=B").first[:text]

      expect(text).to start_with("Reset A=B")
      expect(store.all_overrides).not_to have_key("A=B")
    end

    it "the reset endpoint takes an invalid name out, without an error" do
      delete "/_profiler/api/env_vars/reset?key=#{CGI.escape("A=B")}", {}, writing

      expect(last_response.status).to eq(200)
      expect(Profiler.env_override_store.all_overrides).not_to have_key("A=B")
    end
  end
end
