# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "rbconfig"
require "profiler/mcp/server"

RSpec.describe "MCP resources/read" do
  describe "an unknown resource URI" do
    let(:executable) { File.expand_path("../../exe/profiler-mcp", __dir__) }
    let(:lib) { File.expand_path("../../lib", __dir__) }

    def resource_read_response(uri)
      requests = [
        { jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "resources/read", params: { uri: uri } }
      ].map { |request| JSON.generate(request) }.join("\n")
      out, err, status = Open3.capture3({}, RbConfig.ruby, "-I", lib, executable, stdin_data: "#{requests}\n")
      expect(status).to be_success, err

      response = out.lines.filter_map { |line| JSON.parse(line) rescue nil }.find { |message| message["id"] == 2 }
      expect(response).not_to be_nil, "no answer to resources/read: #{out}#{err}"
      response
    end

    it "answers a JSON-RPC error instead of a success with nil contents" do
      response = resource_read_response("profiler://does-not-exist")

      expect(response).not_to have_key("result")
      expect(response.dig("error", "code")).to eq(-32602)
      expect(response.dig("error", "message")).to include("Resource not found")
    end

    it "still answers normally for a known resource" do
      response = resource_read_response("profiler://recent")

      expect(response).not_to have_key("error")
      expect(response.dig("result", "contents")).to be_a(Array)
    end
  end
end
