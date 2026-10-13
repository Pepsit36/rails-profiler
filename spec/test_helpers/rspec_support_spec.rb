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

  it "records a passing example as passed" do
    run_group { it("passes") { expect(1).to eq(1) } }

    data = test_data("passes")
    expect(data["status"]).to eq("passed")
    expect(data["exception_message"]).to be_nil
  end

  it "records a failing example as failed, with its message" do
    examples = run_group { it("fails") { expect(1).to eq(2) } }

    expect(examples.first.execution_result.status).to eq(:failed)
    data = test_data("fails")
    expect(data["status"]).to eq("failed")
    expect(data["exception_message"]).to include("expected: 2")
  end

  it "records an example failing in an after hook as failed" do
    run_group do
      after { raise "teardown broke" }
      it("fails late") { expect(1).to eq(1) }
    end

    data = test_data("fails late")
    expect(data["status"]).to eq("failed")
    expect(data["exception_message"]).to include("teardown broke")
  end

  it "records an example marked pending in its body as pending" do
    examples = run_group do
      it("is pending") do
        pending("not implemented yet")
        expect(1).to eq(2)
      end
    end

    expect(examples.first.execution_result.status).to eq(:pending)
    data = test_data("is pending")
    expect(data["status"]).to eq("pending")
    expect(data["skip_reason"]).to eq("not implemented yet")
  end

  it "records an example skipped in its body as pending" do
    run_group { it("is skipped") { skip("later") } }

    data = test_data("is skipped")
    expect(data["status"]).to eq("pending")
    expect(data["skip_reason"]).to eq("later")
  end

  it "records a pending example that unexpectedly passes as failed" do
    run_group do
      it("is fixed") do
        pending("should still fail")
        expect(1).to eq(1)
      end
    end

    expect(test_data("is fixed")["status"]).to eq("failed")
  end
end
