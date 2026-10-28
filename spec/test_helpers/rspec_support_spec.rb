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
  # before_install runs first, with the configuration, to register what a
  # suite sets up before calling install.
  def run_group(before_install: nil, &body)
    group = nil
    RSpec::Core::Sandbox.sandboxed do |config|
      before_install&.call(config)
      described_class.install(config)
      group = RSpec.describe("Sandboxed group", &body)
      group.run(RSpec::Core::NullReporter)
    end
    group.examples
  end

  def test_profiles(name)
    Profiler.storage.list(limit: 50).select do |p|
      p.profile_type == "test" && p.collector_data("test")["test_name"] == "Sandboxed group #{name}"
    end
  end

  def test_data(name)
    profile = test_profiles(name).first
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

  it "records an example tagged :aggregate_failures with failing expectations as failed" do
    examples = run_group do
      it("aggregates", :aggregate_failures) do
        expect(1).to eq(2)
        expect(3).to eq(4)
      end
    end

    expect(examples.first.execution_result.status).to eq(:failed)
    data = test_data("aggregates")
    expect(data["status"]).to eq("failed")
    expect(data["exception_message"]).to include("Got 2 failures")
  end

  it "records :aggregate_failures set for every example by the suite as failed" do
    run_group(before_install: ->(config) { config.define_derived_metadata { |meta| meta[:aggregate_failures] = true } }) do
      it("fails once") { expect(1).to eq(2) }
    end

    expect(test_data("fails once")["status"]).to eq("failed")
  end

  it "records an example failed by an around hook the suite registered before install as failed" do
    run_group(before_install: ->(config) { config.around { |example| example.run.tap { raise "around broke" } } }) do
      it("fails in around") { expect(1).to eq(1) }
    end

    data = test_data("fails in around")
    expect(data["status"]).to eq("failed")
    expect(data["exception_message"]).to include("around broke")
  end

  it "profiles each example once, in groups defined before install too" do
    group = nil
    RSpec::Core::Sandbox.sandboxed do |config|
      group = RSpec.describe("Sandboxed group") do
        it("was defined first") { expect(1).to eq(1) }
        context("nested") { it("fails") { expect(1).to eq(2) } }
      end
      described_class.install(config)
      RSpec.describe("Sandboxed group") { it("came after") { expect(1).to eq(1) } }
      RSpec.world.example_groups.each { |g| g.run(RSpec::Core::NullReporter) }
    end

    expect(group.descendants.flat_map(&:examples).map { |e| e.execution_result.status }).to eq(%i[passed failed])
    expect(test_profiles("was defined first").size).to eq(1)
    expect(test_profiles("nested fails").map { |p| p.collector_data("test")["status"] }).to eq(["failed"])
    expect(test_profiles("came after").size).to eq(1)
  end

  it "does not double the profiles when installed twice on the same configuration" do
    group = nil
    RSpec::Core::Sandbox.sandboxed do |config|
      described_class.install(config)
      described_class.install(config)
      group = RSpec.describe("Sandboxed group") { it("runs once") { expect(1).to eq(1) } }
      group.run(RSpec::Core::NullReporter)
    end

    expect(test_profiles("runs once").size).to eq(1)
  end

  describe "automatic install by the railtie" do
    let(:initializer) do
      Profiler::Railtie.initializers.find { |i| i.name == "profiler.setup_test_profiler" }
    end

    def boot_initializer
      initializer.run(nil)
    end

    # Runs the initializer in a fresh RSpec world, then an example, with no
    # manual install, and again with one when manual is true.
    def run_after_boot(manual: false)
      RSpec::Core::Sandbox.sandboxed do |config|
        boot_initializer
        described_class.install(config) if manual
        RSpec.describe("Sandboxed group") { it("runs") { expect(1).to eq(1) } }
          .run(RSpec::Core::NullReporter)
      end
    end

    before do
      require "rails"
      require "profiler/railtie"
      Profiler.configure { |c| c.track_tests = true }
    end

    it "profiles a real example without a manual install" do
      run_after_boot

      expect(test_profiles("runs").size).to eq(1)
      expect(test_data("runs")["framework"]).to eq("rspec")
    end

    it "does not double the profile when the app installs it too" do
      run_after_boot(manual: true)

      expect(test_profiles("runs").size).to eq(1)
    end

    it "installs nothing when track_tests is off" do
      Profiler.configure { |c| c.track_tests = false }
      run_after_boot

      expect(test_profiles("runs")).to be_empty
    end
  end
end
