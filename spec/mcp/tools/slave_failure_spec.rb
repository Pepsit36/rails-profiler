# frozen_string_literal: true

require "spec_helper"
require "profiler/cluster/slave_proxy"
require "profiler/mcp/server"
require "profiler/mcp/tools/set_env_var"
require "profiler/mcp/tools/delete_env_var"
require "profiler/mcp/tools/reset_env_var"
require "profiler/mcp/tools/reset_all_env_vars"

# A slave that answers with an error is never reported as a success.
RSpec.describe "MCP action tools on a slave that refuses" do
  let(:proxy) { instance_double(Profiler::Cluster::SlaveProxy) }

  before { allow(Profiler::MCP::SlaveSupport).to receive(:with_slave_proxy).and_return(proxy) }

  {
    Profiler::MCP::Tools::SetEnvVar => [:patch_json, { "key" => "FOO", "value" => "1" }],
    Profiler::MCP::Tools::DeleteEnvVar => [:patch_json, { "key" => "FOO" }],
    Profiler::MCP::Tools::ResetEnvVar => [:delete_json, { "key" => "FOO" }],
    Profiler::MCP::Tools::ResetAllEnvVars => [:delete_json, {}]
  }.each do |tool, (verb, args)|
    it "#{tool.name.split("::").last} reports the slave's error instead of a success" do
      allow(proxy).to receive(verb).and_return("error" => "nope")

      response = tool.call(args.merge("slave" => "payment"))

      expect(response).to be_a(::MCP::Tool::Response)
      expect(response.error?).to be true
      expect(response.content.first[:text]).to eq("Error: nope")
    end
  end
end
