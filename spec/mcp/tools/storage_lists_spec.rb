# frozen_string_literal: true

require "spec_helper"
require "profiler/mcp/tools/get_profile_ajax"
require "profiler/mcp/tools/query_jobs"
require "profiler/mcp/tools/query_test_profiles"
require "profiler/mcp/tools/query_console_profiles"

# FAB-17 and PERF-03 on the MCP side: get_profile_ajax reads the sub-requests saved after the page,
# and the tools that list one type of profile find it behind newer profiles of another type.
RSpec.describe "MCP tools reading the storage" do
  let(:store) { Profiler::Storage::MemoryStore.new(max_profiles: 5000) }
  let(:base_time) { Time.at(Time.now.to_i - 7200) }

  before { Profiler.instance_variable_set(:@storage, store) }
  after { Profiler.instance_variable_set(:@storage, nil) }

  def save(index, **attrs)
    build_profile(started_at: base_time + index, path: "/p#{index}", **attrs).tap { |p| store.save(p.token, p) }
  end

  def text(result)
    result.map { |part| part[:text] }.join("\n")
  end

  describe Profiler::MCP::Tools::GetProfileAjax do
    it "reports the sub-requests linked to the page after it was saved" do
      parent = save(0)
      save(1, parent_token: parent.token, is_ajax: true, method: "POST", path: "/api/items")
      save(2, parent_token: parent.token, profile_type: "job")

      output = text(described_class.call("token" => parent.token))

      expect(output).to include("**Total AJAX Requests:** 1")
      expect(output).to include("/api/items")
    end
  end

  describe Profiler::MCP::Tools::QueryJobs do
    it "finds the jobs behind 500 newer http profiles" do
      job = save(0, profile_type: "job", collectors_data: { "job" => { "queue" => "default", "status" => "completed" } })
      (1..510).each { |i| save(i) }

      expect(text(described_class.call("limit" => 5))).to include(job.token)
    end
  end

  describe Profiler::MCP::Tools::QueryTestProfiles do
    it "finds the test profiles behind 500 newer http profiles" do
      save(0, profile_type: "test", collectors_data: { "test" => { "test_name" => "works", "status" => "passed" } })
      (1..510).each { |i| save(i) }

      expect(text(described_class.call("limit" => 5))).to include("works")
    end
  end

  describe Profiler::MCP::Tools::QueryConsoleProfiles do
    it "finds the console profiles behind 500 newer http profiles" do
      save(0, profile_type: "console", collectors_data: { "console" => { "expression" => "User.count" } })
      (1..510).each { |i| save(i) }

      expect(text(described_class.call("limit" => 5))).to include("User.count")
    end
  end
end
