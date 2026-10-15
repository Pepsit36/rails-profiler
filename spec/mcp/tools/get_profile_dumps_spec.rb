# frozen_string_literal: true

require "spec_helper"
require "support/mcp_tool_schema"
require "profiler/mcp/tools/get_profile_dumps"

RSpec.describe Profiler::MCP::Tools::GetProfileDumps do
  let(:store) { Profiler::Storage::MemoryStore.new }

  before { Profiler.instance_variable_set(:@storage, store) }
  after { Profiler.instance_variable_set(:@storage, nil) }

  def save(**attrs)
    build_profile(**attrs).tap { |p| store.save(p.token, p) }
  end

  def text(params)
    described_class.call(params).first[:text]
  end

  let(:dumps) do
    {
      "count" => 2,
      "dumps" => [
        { "label" => "user", "file" => "app/models/user.rb", "line" => 12,
          "timestamp" => "2026-10-15T10:00:00Z", "formatted" => "#<User id: 1>" },
        { "value" => { "a" => 1 } }
      ]
    }
  end

  it "declares a required token and an optional slave, both strings" do
    schema = mcp_tool_schema("get_profile_dumps")

    expect(schema[:properties].keys).to contain_exactly(:token, :slave)
    expect(schema[:properties].values.map { |p| p[:type] }).to all(eq("string"))
    expect(schema[:required]).to eq(["token"])
  end

  it "requires a token" do
    expect(text({})).to eq("Error: token parameter is required")
  end

  it "says when the profile does not exist" do
    expect(text("token" => "missing")).to eq("Profile not found: missing")
  end

  it "says when the profile has no dump" do
    profile = save(collectors_data: { "dump" => { "count" => 0, "dumps" => [] } })
    expect(text("token" => profile.token)).to eq("No variable dumps found in this profile")
  end

  it "lists every dump with its label, source, timestamp and value" do
    profile = save(method: "POST", path: "/orders", collectors_data: { "dump" => dumps })

    expect(text("token" => profile.token)).to eq(<<~MD)
      # Variable Dumps: #{profile.token}

      **Request:** POST /orders
      **Total Dumps:** 2

      ## user
      - **Source:** app/models/user.rb:12
      - **Timestamp:** 2026-10-15T10:00:00Z

      ```
      #<User id: 1>
      ```

      ## Dump 2

      ```
      #{{ "a" => 1 }.inspect}
      ```
    MD
  end

  it "reads the most recent profile for the latest token" do
    save(started_at: Time.now - 60, path: "/older", collectors_data: { "dump" => dumps })
    save(started_at: Time.now, path: "/newer", collectors_data: { "dump" => dumps })

    expect(text("token" => "latest")).to include("**Request:** GET /newer")
  end

  it "reads the profile from the slave named in the params" do
    slave_store = Profiler::Storage::MemoryStore.new
    profile = build_profile(path: "/on-slave", collectors_data: { "dump" => dumps })
    slave_store.save(profile.token, profile)
    allow(Profiler::MCP::SlaveSupport).to receive(:resolve_storage)
      .with(hash_including("slave" => "payment")).and_return(slave_store)

    expect(text("token" => profile.token, "slave" => "payment")).to include("**Request:** GET /on-slave")
  end
end
