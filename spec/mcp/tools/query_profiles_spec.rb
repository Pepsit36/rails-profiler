# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "support/mcp_tool_schema"
require "profiler/mcp/tools/query_profiles"

RSpec.describe Profiler::MCP::Tools::QueryProfiles do
  let(:store) { Profiler::Storage::MemoryStore.new }
  let(:base_time) { Time.at(Time.now.to_i - 3600) }

  before { Profiler.instance_variable_set(:@storage, store) }
  after { Profiler.instance_variable_set(:@storage, nil) }

  def save(index, **attrs)
    build_profile(started_at: base_time + index, **attrs).tap { |p| store.save(p.token, p) }
  end

  def text(params = {})
    described_class.call(params).first[:text]
  end

  def rows(output)
    output.lines.map(&:chomp).select { |l| l.start_with?("| ") }.drop(1)
  end

  it "takes only optional filters" do
    schema = mcp_tool_schema("query_profiles")

    expect(schema[:properties].transform_values { |p| p[:type] }).to eq(
      path: "string", method: "string", min_duration: "number", profile_type: "string",
      limit: "number", fields: "array", cursor: "string", slave: "string"
    )
    expect(schema[:properties][:fields][:items]).to eq(type: "string")
    expect(schema).not_to have_key(:required)
  end

  it "says so when nothing matches" do
    expect(text).to eq("No profiles found matching the criteria.")
  end

  it "lists the profiles, newest first, with every column by default" do
    save(0, path: "/old", duration: 12.345, collectors_data: { "database" => { "total_queries" => 3 } })
    newest = save(1, path: "/new", method: "POST", status: 201)

    output = text

    expect(output).to start_with("# Profiled Requests\n\nFound 2 profiles:\n")
    expect(output).to include("| Time | Type | Method | Path | Duration | Queries | Status | Token |")
    expect(rows(output).first).to eq(
      "| #{newest.started_at.strftime('%Y-%m-%d %H:%M:%S')} | http | POST | /new | 10.0ms | 0 | 201 | #{newest.token} |"
    )
    expect(rows(output).last).to include("| /old | 12.35ms | 3 | 200 |")
    expect(output).not_to include("Next cursor")
  end

  it "filters on path, method, minimum duration and type" do
    save(0, path: "/users/1", method: "GET", duration: 5.0)
    save(1, path: "/users/2", method: "POST", duration: 50.0)
    save(2, path: "/orders", method: "POST", duration: 80.0)
    save(3, path: "/users/3", method: "POST", duration: 90.0, profile_type: "job")

    output = text("path" => "/users", "method" => "post", "min_duration" => 40, "profile_type" => "http",
                  "fields" => %w[path])

    expect(rows(output)).to eq(["| /users/2 |"])
  end

  it "keeps only the valid fields asked for" do
    profile = save(0)

    output = text("fields" => %w[token nonsense status])

    expect(output).to include("| Token | Status |")
    expect(rows(output)).to eq(["| #{profile.token} | 200 |"])
  end

  it "gives a cursor when the page is full, and the cursor returns the older profiles" do
    3.times { |i| save(i, path: "/p#{i}") }

    first_page = text("limit" => 2, "fields" => %w[path])
    cursor = first_page[/Next cursor: (\S+)\*/, 1]

    expect(rows(first_page)).to eq(["| /p2 |", "| /p1 |"])
    expect(cursor).to eq((base_time + 1).iso8601(6))
    expect(rows(text("limit" => 2, "fields" => %w[path], "cursor" => cursor))).to eq(["| /p0 |"])
  end

  it "does not lose a profile to another one started within the same second" do
    save(0, path: "/same-second-0")
    build_profile(started_at: base_time + 0.5, path: "/same-second-1").tap { |p| store.save(p.token, p) }
    build_profile(started_at: base_time + 0.9, path: "/same-second-2").tap { |p| store.save(p.token, p) }

    first_page = text("limit" => 2, "fields" => %w[path])
    cursor = first_page[/Next cursor: (\S+)\*/, 1]

    expect(rows(first_page)).to eq(["| /same-second-2 |", "| /same-second-1 |"])
    expect(rows(text("limit" => 2, "fields" => %w[path], "cursor" => cursor))).to eq(["| /same-second-0 |"])
  end

  context "on the SQLite store" do
    let(:dir) { Dir.mktmpdir }
    let(:store) do
      require "profiler/storage/sqlite_store"
      Profiler::Storage::SqliteStore.new(database: File.join(dir, "p.db"), blob_path: File.join(dir, "blobs"), max_profiles: nil)
    end

    after { FileUtils.remove_entry(dir) }

    it "does not lose a profile to another one started within the same second" do
      save(0, path: "/same-second-0")
      build_profile(started_at: base_time + 0.5, path: "/same-second-1").tap { |p| store.save(p.token, p) }
      build_profile(started_at: base_time + 0.9, path: "/same-second-2").tap { |p| store.save(p.token, p) }

      first_page = text("limit" => 2, "fields" => %w[path])
      cursor = first_page[/Next cursor: (\S+)\*/, 1]

      expect(rows(first_page)).to eq(["| /same-second-2 |", "| /same-second-1 |"])
      expect(rows(text("limit" => 2, "fields" => %w[path], "cursor" => cursor))).to eq(["| /same-second-0 |"])
    end
  end

  it "ignores a cursor that is not a time" do
    save(0)

    expect(text("cursor" => "not-a-time")).to include("Found 1 profiles")
  end

  it "shows a dash for a profile without duration" do
    profile = save(0)
    allow(profile).to receive(:duration).and_return(nil)
    allow(store).to receive(:list).and_return([profile])

    expect(text("fields" => %w[duration])).to include("| - |")
  end

  it "reads the profiles of a slave" do
    require "profiler/cluster/slave_proxy"
    proxy = instance_double(Profiler::Cluster::SlaveProxy)
    allow(Profiler::MCP::SlaveSupport).to receive(:resolve_storage).with(hash_including("slave" => "payment")).and_return(proxy)
    expect(proxy).to receive(:list).with(limit: 100, type: nil).and_return([build_profile(path: "/remote")])

    expect(text("slave" => "payment", "fields" => %w[path])).to include("| /remote |")
  end
end
