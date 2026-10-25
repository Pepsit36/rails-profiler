# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/mcp/tools/set_env_var"

RSpec.describe Profiler::MCP::Tools::SetEnvVar do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:store) { Profiler::EnvOverrideStore.new }

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.tmp_path = Pathname.new(tmp_dir)
    end
    Profiler.instance_variable_set(:@env_override_store, store)
    File.write(File.join(tmp_dir, "env_overrides.json"), "{}")
    ENV.delete("TEST_VAR")
  end

  after do
    ENV.delete("TEST_VAR")
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def call(params)
    described_class.call(params)
  end

  it "requires a key" do
    result = call("key" => "", "value" => "test")
    expect(result.first[:text]).to include("Error: key cannot be blank")
  end

  it "sets a non-empty value" do
    result = call("key" => "TEST_VAR", "value" => "test_value")
    expect(result.first[:text]).to include("Set TEST_VAR=test_value")
    expect(ENV["TEST_VAR"]).to eq("test_value")
  end

  it "deletes an empty value (consistent with EnvVarsController)" do
    ENV["TEST_VAR"] = "original"
    store.set("TEST_VAR", "original")

    result = call("key" => "TEST_VAR", "value" => "")
    expect(result.first[:text]).to include("Deleted TEST_VAR")
    expect(ENV["TEST_VAR"]).to be_nil
  end

  it "handles nil value as empty" do
    ENV["TEST_VAR"] = "original"
    store.set("TEST_VAR", "original")

    result = call("key" => "TEST_VAR", "value" => nil)
    expect(result.first[:text]).to include("Deleted TEST_VAR")
    expect(ENV["TEST_VAR"]).to be_nil
  end
end
