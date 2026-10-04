# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/mcp/tools/reset_env_var"

RSpec.describe Profiler::MCP::Tools::ResetEnvVar do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:store) { Profiler::EnvOverrideStore.new }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.tmp_path = Pathname.new(tmp_dir)
    end
    Profiler.instance_variable_set(:@env_override_store, store)
    File.write(
      File.join(tmp_dir, "env_overrides.json"),
      JSON.generate("PROFILER_MCP_A" => { "value" => "dev-override", "original" => "dev-machine-value" })
    )
    ENV["PROFILER_MCP_A"] = "deployed-a"
  end

  after do
    ENV.delete("PROFILER_MCP_A")
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def text
    described_class.call("key" => "PROFILER_MCP_A").first[:text]
  end

  it "says the original value was restored, without showing it, where overrides apply" do
    expect(text).to eq("Reset PROFILER_MCP_A: override removed, original value restored in this process.")
    expect(ENV["PROFILER_MCP_A"]).to eq("dev-machine-value")
  end

  context "in production" do
    before { stub_const("Rails", double("Rails", env: ActiveSupport::StringInquirer.new("production"))) }

    it "says ENV was left unchanged when this process never changed the key" do
      expect(text).to eq("Reset PROFILER_MCP_A: override removed, ENV left unchanged in this process.")
      expect(text).not_to include("dev-machine-value")
      expect(ENV["PROFILER_MCP_A"]).to eq("deployed-a")
    end

    it "says the value was restored when this process changed the key itself" do
      store.set("PROFILER_MCP_A", "changed-here")
      ENV["PROFILER_MCP_A"] = "changed-here"
      expect(text).to eq("Reset PROFILER_MCP_A: override removed, original value restored in this process.")
      expect(ENV["PROFILER_MCP_A"]).to eq("deployed-a")
    end
  end
end
