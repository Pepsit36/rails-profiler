# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "profiler/mcp/server"

# config.mcp_read_only is set in an initializer of the application. The gem's own executable,
# exe/profiler-mcp, does not boot the application: PROFILER_MCP_READ_ONLY is the only way to make
# it read-only.
RSpec.describe "MCP read-only mode" do
  around do |example|
    saved = ENV.to_h
    example.run
  ensure
    ENV.replace(saved)
    Profiler.configuration.mcp_read_only = false
  end

  describe Profiler::MCP::Server, ".read_only?" do
    before { ENV.delete("PROFILER_MCP_READ_ONLY") }

    it "is false by default" do
      expect(described_class.read_only?).to be(false)
    end

    it "is true with config.mcp_read_only, whatever PROFILER_MCP_READ_ONLY says" do
      Profiler.configuration.mcp_read_only = true
      ENV["PROFILER_MCP_READ_ONLY"] = "0"

      expect(described_class.read_only?).to be(true)
    end

    it "is true with any PROFILER_MCP_READ_ONLY but an empty one, 0, false, no or off" do
      %w[1 true TRUE yes on anything].each do |value|
        ENV["PROFILER_MCP_READ_ONLY"] = value
        expect(described_class.read_only?).to be(true), value
      end
      ["", " ", "0", "false", "No", "OFF"].each do |value|
        ENV["PROFILER_MCP_READ_ONLY"] = value
        expect(described_class.read_only?).to be(false), value.inspect
      end
    end
  end

  describe "exe/profiler-mcp" do
    let(:executable) { File.expand_path("../../exe/profiler-mcp", __dir__) }
    let(:lib) { File.expand_path("../../lib", __dir__) }

    # Starts the executable over stdio, as an MCP client does, and returns the names tools/list
    # gives.
    def listed_tools(env)
      requests = [
        { jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "tools/list" }
      ].map { |request| JSON.generate(request) }.join("\n")
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, executable, stdin_data: "#{requests}\n")
      expect(status).to be_success, err

      list = out.lines.filter_map { |line| JSON.parse(line) rescue nil }.find { |message| message["id"] == 2 }
      expect(list).not_to be_nil, "no answer to tools/list: #{out}#{err}"
      list.dig("result", "tools").map { |tool| tool["name"] }
    end

    it "lists the write tools without PROFILER_MCP_READ_ONLY" do
      expect(listed_tools("PROFILER_MCP_READ_ONLY" => nil)).to include(*Profiler::MCP::Server::WRITE_TOOLS)
    end

    it "leaves out the write tools with PROFILER_MCP_READ_ONLY=1" do
      names = listed_tools("PROFILER_MCP_READ_ONLY" => "1")

      expect(names).not_to include(*Profiler::MCP::Server::WRITE_TOOLS)
      expect(names).to include("query_profiles", "get_profile", "list_env_vars")
    end
  end
end
