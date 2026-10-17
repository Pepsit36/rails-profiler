# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"
require "json"

# exe/profiler-mcp does not boot the application, so it has to pick a storage itself: with the
# :memory default it never saw a profile the application had written.
RSpec.describe "exe/profiler-mcp storage" do
  let(:executable) { File.expand_path("../../exe/profiler-mcp", __dir__) }
  let(:lib) { File.expand_path("../../lib", __dir__) }

  it "lists the profiles the application's file storage wrote under ./tmp/rails-profiler" do
    Dir.mktmpdir("profiler-mcp-exe") do |dir|
      token = Dir.chdir(dir) do
        store = Profiler::Storage::FileStore.new(path: File.join(dir, "tmp", "rails-profiler", "profiles"))
        profile = Profiler::Models::Profile.new
        profile.path = "/from-the-app"
        profile.method = "GET"
        profile.status = 200
        profile.duration = 12.0
        store.save(profile.token, profile)
        profile.token
      end

      requests = [
        { jsonrpc: "2.0", id: 1, method: "initialize",
          params: { protocolVersion: "2025-03-26", capabilities: {}, clientInfo: { name: "spec", version: "1" } } },
        { jsonrpc: "2.0", method: "notifications/initialized" },
        { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "query_profiles", arguments: {} } }
      ].map { |request| JSON.generate(request) }.join("\n")
      out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, executable, stdin_data: "#{requests}\n", chdir: dir)
      expect(status).to be_success, err

      answer = out.lines.filter_map { |line| JSON.parse(line) rescue nil }.find { |m| m["id"] == 2 }
      text = answer.dig("result", "content", 0, "text")
      expect(text).to include("/from-the-app"), text
      expect(text).to include(token[0, 8])
    end
  end
end
