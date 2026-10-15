# frozen_string_literal: true

require "spec_helper"
require "support/mcp_tool_schema"
require "profiler/cluster/slave_registry"
require "profiler/mcp/tools/list_slaves"

RSpec.describe Profiler::MCP::Tools::ListSlaves do
  before { Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new) }
  after { Profiler.instance_variable_set(:@slave_registry, nil) }

  def text
    described_class.call({}).first[:text]
  end

  it "takes no argument" do
    schema = mcp_tool_schema("list_slaves")

    expect(schema[:properties]).to eq({})
    expect(schema).not_to have_key(:required)
  end

  it "says so when no slave is connected" do
    expect(text).to eq("No slave profilers connected.")
  end

  it "lists each connected slave with its status and timestamps" do
    entry = Profiler.slave_registry.register(name: "payment", url: "http://payment:3001")

    expect(text.lines.map(&:chomp)).to eq([
      "# Connected Slave Profilers",
      "",
      "| Name | URL | Status | Registered At | Last Heartbeat |",
      "|------|-----|--------|--------------|----------------|",
      "| payment | http://payment:3001 | online | #{entry.registered_at.iso8601} | #{entry.last_heartbeat_at.iso8601} |"
    ])
  end

  it "reports a slave past the offline threshold as offline" do
    entry = Profiler.slave_registry.register(name: "billing", url: "http://billing:3002")
    entry.last_heartbeat_at = Time.now - Profiler.configuration.cluster_offline_threshold - 1

    expect(text).to include("| billing | http://billing:3002 | offline |")
  end
end
