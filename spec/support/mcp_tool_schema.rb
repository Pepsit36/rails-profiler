# frozen_string_literal: true

require "profiler/mcp/server"

# The input schema an MCP client receives for a tool, as tools/list returns it.
def mcp_tool_schema(name)
  server = Profiler::MCP::Server.new.instance_variable_get(:@server)
  response = server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list", params: {} })
  tool = response[:result][:tools].find { |t| t[:name] == name } or raise "No MCP tool named #{name}"
  tool[:inputSchema]
end
