# frozen_string_literal: true

require "spec_helper"
require "support/mcp_tool_schema"
require "profiler/mcp/tools/clear_profiles"

RSpec.describe Profiler::MCP::Tools::ClearProfiles do
  let(:store) { Profiler::Storage::MemoryStore.new }

  before { Profiler.instance_variable_set(:@storage, store) }
  after { Profiler.instance_variable_set(:@storage, nil) }

  def text(params = {})
    described_class.call(params).first[:text]
  end

  def save(**attrs)
    build_profile(**attrs).tap { |p| store.save(p.token, p) }
  end

  it "takes an optional type and slave" do
    schema = mcp_tool_schema("clear_profiles")

    expect(schema[:properties].keys).to contain_exactly(:type, :slave)
    expect(schema[:properties].values.map { |p| p[:type] }).to all(eq("string"))
    expect(schema).not_to have_key(:required)
  end

  it "clears every profile when no type is given" do
    save
    save(profile_type: "job")

    expect(text).to eq("Cleared all profiles.")
    expect(store.list).to be_empty
  end

  it "clears only the profiles of the given type" do
    http = save
    save(profile_type: "job")

    expect(text("type" => "job")).to eq("Cleared job profiles.")
    expect(store.list.map(&:token)).to eq([http.token])
  end

  it "refuses an unknown type without clearing anything" do
    save

    expect(text("type" => "mail")).to eq("Error: type must be 'http', 'job', 'test', or 'console'")
    expect(store.list.size).to eq(1)
  end

  context "with a slave" do
    let(:proxy) { instance_double(Profiler::Cluster::SlaveProxy) }

    before do
      require "profiler/cluster/slave_proxy"
      allow(Profiler::MCP::SlaveSupport).to receive(:with_slave_proxy).and_return(proxy)
    end

    it "asks the slave to clear everything, leaving the local storage alone" do
      save
      expect(proxy).to receive(:delete_json).with("/_profiler/api/profiles/clear")

      expect(text("slave" => "payment")).to eq("Cleared all profiles.")
      expect(store.list.size).to eq(1)
    end

    it "passes the type on to the slave" do
      expect(proxy).to receive(:delete_json).with("/_profiler/api/profiles/clear?type=test")

      expect(text("slave" => "payment", "type" => "test")).to eq("Cleared test profiles.")
    end
  end
end
