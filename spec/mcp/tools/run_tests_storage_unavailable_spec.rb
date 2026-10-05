# frozen_string_literal: true

require "spec_helper"
require "profiler/mcp/tools/run_tests"

# A storage that could not be created is said to the MCP client as an error, not taken for a run
# without profiles.
RSpec.describe "run_tests with the storage unavailable" do
  before do
    Profiler.instance_variable_set(:@storage, Profiler::Storage::Unavailable.new(RuntimeError.new("index is a symbolic link")))
  end

  it "lets Storage::Unavailable::Error through, for the MCP server to answer as an error" do
    expect { Profiler::MCP::Tools::RunTests.collect_run_profiles(Time.now - 60) }
      .to raise_error(Profiler::Storage::Unavailable::Error, /symbolic link/)
  end
end
