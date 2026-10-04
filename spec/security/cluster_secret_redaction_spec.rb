# frozen_string_literal: true

require "spec_helper"
require "profiler/redaction"

# The cluster secret is masked by value wherever the profiler captures it, in addition to the
# masking by name: it may travel under a name no filter knows.
RSpec.describe "Cluster secret redaction" do
  let(:secret) { "c1uster-shared-value-0123456789abcdef" }
  let(:mask) { Profiler::Redaction::MASK }

  before { Profiler.configure { |config| config.cluster_secret = secret } }

  it "masks params holding it, whole or embedded" do
    filtered = Profiler::Redaction.filter_hash("q" => secret, "nested" => { "list" => ["x #{secret} y"] })

    expect(filtered).to eq("q" => mask, "nested" => { "list" => ["x #{mask} y"] })
  end

  it "masks incoming, response and outbound headers under any name" do
    headers = { "X-Cluster-Auth" => secret, "Referer" => "http://h/?auth=#{secret}", "Accept" => "*/*" }

    expect(Profiler::Redaction.filter_headers(headers))
      .to eq("X-Cluster-Auth" => mask, "Referer" => "http://h/?auth=#{mask}", "Accept" => "*/*")
  end

  it "masks it in URLs, query strings, bodies and named values" do
    expect(Profiler::Redaction.filter_url("https://h/p?auth=#{secret}")).to eq("https://h/p?auth=#{mask}")
    expect(Profiler::Redaction.filter_query("auth=#{secret}")).to eq("auth=#{mask}")
    expect(Profiler::Redaction.filter_body(%({"auth":"#{secret}"}), "application/json")).not_to include(secret)
    expect(Profiler::Redaction.filter_body("<p>#{secret}</p>".b, "text/html")).to eq("<p>#{mask}</p>")
    expect(Profiler::Redaction.filter_named("column", secret)).to eq(mask)
  end

  it "masks it in ENV, listed variables and overrides included" do
    Profiler.configuration.env_allowlist = :all

    expect(Profiler::Redaction.env_snapshot("CLUSTER_PSK" => secret, "PORT" => "3000"))
      .to eq("CLUSTER_PSK" => mask, "PORT" => "3000")
    expect(Profiler::Redaction.env_value("CLUSTER_PSK", secret)).to eq(mask)
    expect(Profiler::Redaction.env_overrides("CLUSTER_PSK" => { "value" => secret, "original" => nil }))
      .to eq("CLUSTER_PSK" => { "value" => mask, "original" => nil })
  end

  it "masks it even with redact_sensitive_data off" do
    Profiler.configuration.redact_sensitive_data = false

    expect(Profiler::Redaction.filter_headers("X-Cluster-Auth" => secret)).to eq("X-Cluster-Auth" => mask)
    expect(Profiler::Redaction.filter_hash("q" => secret)).to eq("q" => mask)
  end

  it "masks it in the params of a profile, with redact_sensitive_data off" do
    Profiler.configuration.redact_sensitive_data = false
    profile = Profiler::Models::Profile.new(Rack::Request.new(Rack::MockRequest.env_for("/?q=#{secret}")))

    expect(profile.params.to_s).not_to include(secret)
  end

  it "leaves values alone when no secret is configured" do
    Profiler.configuration.cluster_secret = nil
    expect(Profiler::Redaction.filter_hash("q" => secret)).to eq("q" => secret)
  end

  it "replaces a short secret only as a whole value" do
    Profiler.configuration.cluster_secret = "abc"

    expect(Profiler::Redaction.filter_hash("a" => "abc", "b" => "xabcx")).to eq("a" => mask, "b" => "xabcx")
  end

  # Free text: what collectors capture without a name to filter on. Every collector stores its
  # data through Profile#add_collector_data, and the console expression becomes the path.
  describe "free text captured by collectors" do
    require "profiler/collectors/log_collector"
    require "profiler/collectors/exception_collector"
    require "profiler/collectors/dump_collector"

    let(:profile) { Profiler::Models::Profile.new }

    after do
      Thread.current[:profiler_logs] = nil
      Thread.current[:profiler_dumps] = nil
    end

    it "masks it in log lines" do
      collector = Profiler::Collectors::LogCollector.new(profile)
      Thread.current[:profiler_logs] = [{ level: "INFO", message: "joining with #{secret}", timestamp: "t" }]
      collector.collect

      expect(profile.collector_data("logs").to_s).not_to include(secret)
      expect(profile.collector_data("logs").to_s).to include("joining with #{mask}")
    end

    it "masks it in exception messages" do
      collector = Profiler::Collectors::ExceptionCollector.new(profile)
      collector.subscribe
      collector.capture(RuntimeError.new("refused #{secret}"))
      collector.collect

      expect(profile.collector_data("exception").to_s).not_to include(secret)
    end

    it "masks it in dumps" do
      collector = Profiler::Collectors::DumpCollector.new(profile)
      Thread.current[:profiler_dumps] = [{ value: { "conf" => secret }, file: "f", line: 1, label: "l", timestamp: "t" }]
      collector.collect

      expect(profile.collector_data("dump").to_s).not_to include(secret)
    end

    it "masks it in whatever any collector stores, SQL text included" do
      profile.add_collector_data("database", { queries: [{ sql: "SELECT 1 WHERE k = '#{secret}'" }] })

      expect(profile.collector_data("database").to_s).not_to include(secret)
    end

    it "masks it in a console expression shown as the path" do
      profile.path = "Profiler.configuration.cluster_secret == '#{secret}'"

      expect(profile.path).not_to include(secret)
    end
  end

  it "masks it in the output of a test run, read back by the API and MCP" do
    require "profiler/test_runner/run_store"
    store = Profiler::TestRunner::RunStore.new
    run = store.create(files: [], framework: "rspec")
    store.append_output(run.id, "ENV dump: #{secret}\n")

    expect(store.find(run.id).to_h[:output]).not_to include(secret)
  end
end
