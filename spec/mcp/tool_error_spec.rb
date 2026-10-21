# frozen_string_literal: true

require "spec_helper"
require "profiler/mcp/server"

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
end
