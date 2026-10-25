# frozen_string_literal: true

require "spec_helper"
require "support/mcp_tool_schema"
require "profiler/mcp/tools/explain_query"

RSpec.describe Profiler::MCP::Tools::ExplainQuery do
  before do
    # The environment gate has its own spec (spec/explain_environment_gate_spec.rb); here the
    # tool is exercised wherever the suite runs, with or without Rails loaded.
    Profiler.configure do |c|
      c.enabled = true
      c.allow_explain_outside_development = true
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def text(params)
    described_class.call(params).first[:text]
  end

  it "declares a required token string, a required integer query_index and an optional slave" do
    schema = mcp_tool_schema("explain_query")

    expect(schema[:properties].transform_values { |p| p[:type] })
      .to eq(token: "string", query_index: "integer", slave: "string")
    expect(schema[:required]).to contain_exactly("token", "query_index")
  end

  it "requires a token" do
    expect(text("query_index" => 0)).to eq("Error: token parameter is required")
  end

  it "requires a query index" do
    expect(text("token" => "abc")).to eq("Error: query_index parameter is required")
  end

  it "refuses when the profiler is disabled" do
    Profiler.configuration.enabled = false
    expect(Profiler::ExplainRunner).not_to receive(:run)

    expect(text("token" => "abc", "query_index" => 0))
      .to eq("Error: EXPLAIN is only available when the profiler is enabled")
  end

  it "shows a JSON plan as pretty-printed JSON" do
    allow(Profiler::ExplainRunner).to receive(:run).with("abc", 2)
      .and_return(adapter: "postgresql", format: "json", result: [{ "Plan" => { "Node Type" => "Seq Scan" } }])

    output = text("token" => "abc", "query_index" => "2")

    expect(output).to start_with("# EXPLAIN ANALYZE ")
    expect(output.lines.first).to end_with("Query #2\n")
    expect(output).to include("Adapter: `postgresql`\n")
    expect(output).to include("```json\n#{JSON.pretty_generate([{ "Plan" => { "Node Type" => "Seq Scan" } }])}\n```")
  end

  it "shows a text plan as it came" do
    allow(Profiler::ExplainRunner).to receive(:run).with("abc", 0)
      .and_return(adapter: "sqlite3", format: "text", result: "SCAN users")

    expect(text("token" => "abc", "query_index" => 0)).to end_with("Adapter: `sqlite3`\n\n```\nSCAN users\n```")
  end

  it "turns the runner's argument errors into an error message" do
    expect(text("token" => "missing", "query_index" => 0)).to eq("Error: Profile not found: missing")
  end

  it "reports any other failure of the runner without its message, which is logged instead" do
    allow(Profiler::ExplainRunner).to receive(:run).and_raise(RuntimeError, "connection lost")
    expect(Profiler).to receive(:log_error).with(a_string_including("explain_query"), an_instance_of(RuntimeError))

    expect(text("token" => "abc", "query_index" => 0)).to eq("EXPLAIN failed (the application log has the details)")
  end

  it "resolves 'latest' token to the most recent profile" do
    profile = build_profile(path: "/latest", collectors_data: { "database" => { "queries" => [] } })
    Profiler.storage.save(profile.token, profile)
    allow(Profiler::ExplainRunner).to receive(:run).with(profile.token, 0)
      .and_return(adapter: "postgresql", format: "text", result: "SCAN users")

    output = text("token" => "latest", "query_index" => 0)

    expect(output).to include("Adapter: `postgresql`")
    expect(output).to include("SCAN users")
  end

  context "on a slave" do
    let(:proxy) { instance_double("Profiler::Cluster::SlaveProxy") }

    before do
      allow(Profiler::MCP::SlaveSupport).to receive(:with_slave_proxy)
        .with(hash_including("slave" => "payment")).and_return(proxy)
    end

    it "asks the slave to run EXPLAIN, with an integer index" do
      expect(proxy).to receive(:post_json).with("/_profiler/api/explain", { token: "abc", query_index: 3 })
        .and_return("adapter" => "postgresql")
      expect(Profiler::ExplainRunner).not_to receive(:run)

      expect(text("token" => "abc", "query_index" => "3", "slave" => "payment"))
        .to eq({ "adapter" => "postgresql" }.inspect)
    end

    it "relays the slave's error" do
      allow(proxy).to receive(:post_json).and_return("error" => "Profile not found: abc")

      expect(text("token" => "abc", "query_index" => 0, "slave" => "payment"))
        .to eq("Error: Profile not found: abc")
    end
  end
end
