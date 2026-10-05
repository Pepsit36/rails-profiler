# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "profiler/mcp/tools/set_env_var"

# BUG-09: Configuration#tmp_path is a Pathname whatever it was set from, and outside Rails, so that
# the env overrides work there; and a failure to write them reaches the caller.
RSpec.describe "Configuration#tmp_path and the env overrides" do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  ensure
    ENV.delete("PROFILER_SPEC_TMP_PATH")
    Profiler.instance_variable_set(:@env_override_store, nil)
  end

  describe Profiler::Configuration do
    it "defaults to a Pathname outside Rails" do
      hide_const("Rails")
      expect(described_class.new.tmp_path).to eq(Pathname.new(File.expand_path("tmp/rails-profiler", Dir.pwd)))
    end

    it "returns a Pathname when set from a String" do
      config = described_class.new
      config.tmp_path = File.join(@root, "profiler")
      expect(config.tmp_path).to eq(Pathname.new(File.join(@root, "profiler")))
    end
  end

  describe Profiler::EnvOverrideStore do
    subject(:store) { described_class.new }

    before do
      Profiler.configure do |config|
        config.enabled = true
        config.tmp_path = File.join(@root, "profiler")
      end
    end

    it "keeps an override when tmp_path was set from a String" do
      store.set("PROFILER_SPEC_TMP_PATH", "1")
      expect(store.all_overrides.dig("PROFILER_SPEC_TMP_PATH", "value")).to eq("1")
    end

    context "when the overrides cannot be written" do
      before do
        File.write(File.join(@root, "blocker"), "")
        Profiler.configuration.tmp_path = File.join(@root, "blocker", "profiler")
      end

      it "raises from the writing methods instead of only warning" do
        %i[set delete].each do |method|
          args = method == :set ? ["PROFILER_SPEC_TMP_PATH", "1"] : ["PROFILER_SPEC_TMP_PATH"]
          expect { store.public_send(method, *args) }.to raise_error(Profiler::EnvOverrideStore::Error)
        end
        expect { store.reset("PROFILER_SPEC_TMP_PATH") }.to raise_error(Profiler::EnvOverrideStore::Error)
        expect { store.reset_all }.to raise_error(Profiler::EnvOverrideStore::Error)
        expect { store.clear }.to raise_error(Profiler::EnvOverrideStore::Error)
      end

      it "makes the MCP tool answer an error and leave ENV alone" do
        response = Profiler::MCP::Tools::SetEnvVar.call("key" => "PROFILER_SPEC_TMP_PATH", "value" => "1")
        expect(response).to be_a(MCP::Tool::Response)
        expect(response.error?).to be true
        expect(response.content.first[:text]).to include("PROFILER_SPEC_TMP_PATH was left unchanged")
        expect(ENV.key?("PROFILER_SPEC_TMP_PATH")).to be false
      end
    end
  end
end
