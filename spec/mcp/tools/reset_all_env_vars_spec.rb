# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "support/mcp_tool_schema"
require "profiler/mcp/tools/reset_all_env_vars"

RSpec.describe Profiler::MCP::Tools::ResetAllEnvVars do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:store) { Profiler::EnvOverrideStore.new }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.tmp_path = Pathname.new(tmp_dir)
    end
    Profiler.instance_variable_set(:@env_override_store, store)
    ENV["PROFILER_MCP_A"] = "original-a"
    ENV.delete("PROFILER_MCP_B")
  end

  after do
    ENV.delete("PROFILER_MCP_A")
    ENV.delete("PROFILER_MCP_B")
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def call(params = {})
    described_class.call(params)
  end

  it "takes only an optional slave" do
    schema = mcp_tool_schema("reset_all_env_vars")

    expect(schema[:properties].keys).to eq([:slave])
    expect(schema[:properties][:slave][:type]).to eq("string")
    expect(schema).not_to have_key(:required)
  end

  it "says so when no override is active" do
    expect(call.first[:text]).to eq("No active overrides to reset.")
  end

  it "restores every overridden variable and counts them" do
    store.set("PROFILER_MCP_A", "changed")
    ENV["PROFILER_MCP_A"] = "changed"
    store.set("PROFILER_MCP_B", "added")
    ENV["PROFILER_MCP_B"] = "added"

    expect(call.first[:text]).to eq("Reset 2 environment variables to original values.")
    expect(ENV["PROFILER_MCP_A"]).to eq("original-a")
    expect(ENV).not_to have_key("PROFILER_MCP_B")
    expect(store.all_overrides).to be_empty
  end

  it "uses the singular for a single variable" do
    store.set("PROFILER_MCP_A", "changed")

    expect(call.first[:text]).to eq("Reset 1 environment variable to original values.")
  end

  it "returns a tool error when the overrides cannot be read" do
    allow(store).to receive(:all_overrides)
      .and_raise(Profiler::EnvOverrideStore::Error, "could not read the overrides")

    response = call

    expect(response).to be_a(::MCP::Tool::Response)
    expect(response.error?).to be true
    expect(response.content).to eq([{ type: "text", text: "Error: could not read the overrides; nothing was changed." }])
  end

  it "asks the slave to reset its own overrides" do
    require "profiler/cluster/slave_proxy"
    proxy = instance_double(Profiler::Cluster::SlaveProxy)
    allow(Profiler::MCP::SlaveSupport).to receive(:with_slave_proxy).and_return(proxy)
    expect(proxy).to receive(:delete_json).with("/_profiler/api/env_vars/reset_all")

    expect(call("slave" => "payment").first[:text]).to eq("Reset all ENV overrides on slave 'payment'.")
  end
end
