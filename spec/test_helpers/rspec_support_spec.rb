# frozen_string_literal: true

require "spec_helper"
require "rspec/core/sandbox"
require "profiler/test_helpers/rspec_support"

# Runs real RSpec examples through the integration, in a sandboxed RSpec world,
# so the hook receives the same RSpec::Core::Example::Procsy it gets in an app.
RSpec.describe Profiler::TestHelpers::RSpecSupport do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.storage = :memory
      c.track_memory = false
    end
  end

  # Defines a group in a fresh RSpec world with the integration installed, runs it,
  # and returns the RSpec examples so their own outcome can be checked too.
  def run_group(&body)
    group = nil
    RSpec::Core::Sandbox.sandboxed do |config|
      described_class.install(config)
      group = RSpec.describe("Sandboxed group", &body)
      group.run(RSpec::Core::NullReporter)
    end
    group.examples
  end

  def test_data(name)
    profile = Profiler.storage.list(limit: 50).find do |p|
      p.profile_type == "test" && p.collector_data("test")["test_name"] == "Sandboxed group #{name}"
    end
    expect(profile).not_to be_nil, "no test profile recorded for #{name.inspect}"
    profile.collector_data("test")
  end

  it "runs the example without raising from the hook and records its location" do
    line = nil
    examples = run_group do
      line = __LINE__ + 1
      it("passes") { expect(1).to eq(1) }
    end

    expect(examples.first.execution_result.exception).to be_nil
    expect(examples.first.execution_result.status).to eq(:passed)
    data = test_data("passes")
    expect(data["test_file"]).to end_with("spec/test_helpers/rspec_support_spec.rb")
    expect(data["test_line"]).to eq(line)
    expect(data["framework"]).to eq("rspec")
  end
end
