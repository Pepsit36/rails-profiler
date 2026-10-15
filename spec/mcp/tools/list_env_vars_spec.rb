# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "support/mcp_tool_schema"
require "profiler/mcp/tools/list_env_vars"

RSpec.describe Profiler::MCP::Tools::ListEnvVars do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:store) { Profiler::EnvOverrideStore.new }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.tmp_path = Pathname.new(tmp_dir)
      c.env_allowlist = %w[PROFILER_MCP_A PROFILER_MCP_B PROFILER_MCP_GONE]
    end
    Profiler.instance_variable_set(:@env_override_store, store)
    ENV["PROFILER_MCP_A"] = "value-a"
    ENV["PROFILER_MCP_B"] = "value-b"
    ENV["PROFILER_MCP_HIDDEN"] = "not-listed"
  end

  after do
    %w[PROFILER_MCP_A PROFILER_MCP_B PROFILER_MCP_HIDDEN PROFILER_MCP_GONE].each { |k| ENV.delete(k) }
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def text(params = {})
    described_class.call(params).first[:text]
  end

  it "takes an optional include_all flag, filter and slave" do
    schema = mcp_tool_schema("list_env_vars")

    expect(schema[:properties].transform_values { |p| p[:type] })
      .to eq(include_all: "boolean", filter: "string", slave: "string")
    expect(schema).not_to have_key(:required)
  end

  describe "the active overrides (default)" do
    it "says so when there is none" do
      expect(text).to eq("No overrides active.")
    end

    it "lists each override with its current and original value, a deleted key as such" do
      store.set("PROFILER_MCP_A", "override-a")
      ENV["PROFILER_MCP_GONE"] = "was-here"
      store.delete("PROFILER_MCP_GONE")
      ENV.delete("PROFILER_MCP_B")
      store.set("PROFILER_MCP_B", "new-b")

      output = text

      expect(output).to start_with("**Active ENV overrides (3)**\n\n| Key | Current Value | Original Value |")
      expect(output).to include("| PROFILER_MCP_A | override-a | value-a |")
      expect(output).to include("| PROFILER_MCP_GONE | (deleted) | was-here |")
      expect(output).to include("| PROFILER_MCP_B | new-b | (unset) |")
    end

    it "masks the values of a key outside the allowlist" do
      store.set("PROFILER_MCP_HIDDEN", "secret")

      expect(text).to include("| PROFILER_MCP_HIDDEN | [FILTERED] | [FILTERED] |")
      expect(text).not_to include("secret")
    end

    it "filters on the key name, case-insensitively" do
      store.set("PROFILER_MCP_A", "override-a")
      store.set("PROFILER_MCP_B", "override-b")

      expect(text("filter" => "mcp_b")).to include("**Active ENV overrides (1)**")
      expect(text("filter" => "mcp_b")).not_to include("PROFILER_MCP_A")
      expect(text("filter" => "nothing")).to eq("No overrides match filter 'nothing'.")
    end
  end

  describe "every variable (include_all)" do
    it "lists the environment, masking keys outside the allowlist and marking overrides" do
      store.set("PROFILER_MCP_A", "override-a")
      ENV["PROFILER_MCP_A"] = "override-a"

      output = text("include_all" => true, "filter" => "profiler_mcp")

      expect(output).to start_with("**ENV variables (3, filtered by 'profiler_mcp')**")
      expect(output).to include("| PROFILER_MCP_A | override-a | ✓ (was: value-a) |")
      expect(output).to include("| PROFILER_MCP_B | value-b |  |")
      expect(output).to include("| PROFILER_MCP_HIDDEN | [FILTERED] |  |")
    end

    it "says so when the filter matches no variable" do
      expect(text("include_all" => true, "filter" => "no_such_variable"))
        .to eq("No environment variables match filter 'no_such_variable'.")
    end
  end

  it "returns a tool error when the overrides cannot be read" do
    allow(store).to receive(:all_overrides).and_raise(Profiler::EnvOverrideStore::Error, "could not read the overrides")

    response = described_class.call({})

    expect(response.error?).to be true
    expect(response.content).to eq([{ type: "text", text: "Error: could not read the overrides." }])
  end

  context "with a slave" do
    let(:proxy) { instance_double(Profiler::Cluster::SlaveProxy) }
    let(:data) do
      {
        "variables" => { "Z_VAR" => "z", "A_VAR" => "a" },
        "overrides" => {
          "A_VAR" => { "value" => "a", "original" => "old-a" },
          "GONE" => { "value" => Profiler::EnvOverrideStore::DELETED_SENTINEL, "original" => nil }
        }
      }
    end

    before do
      require "profiler/cluster/slave_proxy"
      allow(Profiler::MCP::SlaveSupport).to receive(:with_slave_proxy).and_return(proxy)
    end

    it "lists the overrides the slave returns" do
      expect(proxy).to receive(:get_json)
        .with("/_profiler/api/env_vars", include_all: nil, filter: nil).and_return(data)

      expect(text("slave" => "payment")).to eq(
        "**Active ENV overrides (2)**\n\n| Key | Current Value | Original Value |\n|-----|--------------|----------------|\n" \
        "| A_VAR | a | old-a |\n| GONE | (deleted) | (unset) |"
      )
    end

    it "filters the slave overrides and says when none is left" do
      allow(proxy).to receive(:get_json).and_return(data)

      expect(text("slave" => "payment", "filter" => "gone")).to include("**Active ENV overrides (1)**")
      expect(text("slave" => "payment", "filter" => "none")).to eq("No overrides active.")
      allow(proxy).to receive(:get_json).and_return({})
      expect(text("slave" => "payment")).to eq("No overrides active.")
    end

    it "lists every slave variable, sorted, marking the overridden ones" do
      expect(proxy).to receive(:get_json)
        .with("/_profiler/api/env_vars", include_all: true, filter: nil).and_return(data)

      expect(text("slave" => "payment", "include_all" => true)).to eq(
        "**ENV variables (2)**\n\n| Key | Current Value | Overridden |\n|-----|--------------|------------|\n" \
        "| A_VAR | a | ✓ (was: old-a) |\n| Z_VAR | z |  |"
      )
    end

    it "filters every slave variable and says when none matches" do
      allow(proxy).to receive(:get_json).and_return(data)

      expect(text("slave" => "payment", "include_all" => true, "filter" => "z_")).to include("**ENV variables (1)**")
      expect(text("slave" => "payment", "include_all" => true, "filter" => "none"))
        .to eq("No environment variables match filter 'none'.")
    end
  end
end
