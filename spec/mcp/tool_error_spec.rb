# frozen_string_literal: true

require "spec_helper"
require "profiler/mcp/server"
require "net/http"

# A Profiler::Error raised by a tool (a slave that refuses, is offline or answers 500) reaches the
# MCP client as a tool error carrying its message.
RSpec.describe Profiler::MCP::Server do
  it "answers a Profiler::Error of a tool as an error response" do
    server = described_class.new
    tool = server.send(:define_tool, name: "clear_profiles", description: "x", input_schema: { properties: {} },
                                     handler: ->(_params) { raise Profiler::Error, "Slave profiler answered 500" })

    response = tool.call(server_context: nil)

    expect(response.error?).to be true
    expect(response.content).to eq([{ type: "text", text: "Slave profiler answered 500" }])
  end

  it "answers a Net::OpenTimeout as an error response" do
    server = described_class.new
    tool = server.send(:define_tool, name: "list_profiles", description: "x", input_schema: { properties: {} },
                                     handler: ->(_params) { raise Net::OpenTimeout, "Connection timed out" })

    response = tool.call(server_context: nil)

    expect(response.error?).to be true
    expect(response.content).to eq([{ type: "text", text: "Connection timed out" }])
  end

  it "answers a Net::ReadTimeout as an error response" do
    server = described_class.new
    tool = server.send(:define_tool, name: "get_profile", description: "x", input_schema: { properties: {} },
                                     handler: ->(_params) { raise Net::ReadTimeout, "Read timed out" })

    response = tool.call(server_context: nil)

    expect(response.error?).to be true
    expect(response.content.first[:text]).to include("Read timed out")
  end

  it "answers a SystemCallError as an error response" do
    server = described_class.new
    tool = server.send(:define_tool, name: "explain_query", description: "x", input_schema: { properties: {} },
                                     handler: ->(_params) { raise Errno::ECONNREFUSED, "Connection refused" })

    response = tool.call(server_context: nil)

    expect(response.error?).to be true
    expect(response.content.first[:text]).to include("Connection refused")
  end
end
