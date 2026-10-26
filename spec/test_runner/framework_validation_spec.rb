# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "pathname"
require "profiler/test_runner/discovery"
require "profiler/test_runner/runner"

# The framework must be a String or Symbol before .to_sym is called on it.
RSpec.describe "Framework parameter validation" do
  let(:tmpdir) do
    dir = File.realpath(Dir.mktmpdir("profiler_framework_validation_spec"))
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec/fake_spec.rb"), "")
    dir
  end

  before do
    rails_root = Pathname.new(tmpdir)
    rails_stub = Module.new
    rails_stub.define_singleton_method(:root) { rails_root }
    rails_stub.define_singleton_method(:to_s) { "Rails" }
    stub_const("Rails", rails_stub)

    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
    allow(Profiler).to receive(:env_override_store).and_return(
      instance_double(Profiler::EnvOverrideStore, all_overrides: {})
    )
  end

  after do
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
    FileUtils.rm_rf(tmpdir)
    described_class.reset_warnings! if described_class.respond_to?(:reset_warnings!)
  end

  describe "Discovery.files with framework parameter" do
    context "with valid framework parameter" do
      it "accepts a string framework" do
        result = Profiler::TestRunner::Discovery.files(framework: "rspec")
        expect(result).to be_a(Array)
      end

      it "accepts nil framework" do
        result = Profiler::TestRunner::Discovery.files(framework: nil)
        expect(result).to be_a(Array)
      end

      it "accepts rspec as framework" do
        result = Profiler::TestRunner::Discovery.files(framework: "rspec")
        expect(result).to be_a(Array)
      end

      it "accepts minitest as framework" do
        result = Profiler::TestRunner::Discovery.files(framework: "minitest")
        expect(result).to be_a(Array)
      end
    end

    context "with invalid framework parameter" do
      it "raises an error when framework is an integer" do
        expect {
          Profiler::TestRunner::Discovery.files(framework: 123)
        }.to raise_error(/framework must be a string or symbol/i)
      end

      it "still accepts a symbol, which the MCP run_tests tool passes after to_sym" do
        expect { Profiler::TestRunner::Discovery.files(framework: :rspec) }.not_to raise_error
      end

      it "raises an error when framework is an array" do
        expect {
          Profiler::TestRunner::Discovery.files(framework: ["rspec"])
        }.to raise_error(/framework must be a string or symbol/i)
      end

      it "raises an error when framework is a hash" do
        expect {
          Profiler::TestRunner::Discovery.files(framework: { name: "rspec" })
        }.to raise_error(/framework must be a string or symbol/i)
      end

      it "raises an error when framework is a boolean" do
        expect {
          Profiler::TestRunner::Discovery.files(framework: true)
        }.to raise_error(/framework must be a string or symbol/i)
      end
    end
  end

  describe "Runner.start with framework parameter" do
    context "with valid framework parameter" do
      it "accepts a string framework" do
        allow(Profiler::TestRunner::Runner).to receive(:spawn_async)
        expect {
          Profiler::TestRunner::Runner.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        }.not_to raise_error
      end

      it "accepts rspec as framework" do
        allow(Profiler::TestRunner::Runner).to receive(:spawn_async)
        expect {
          Profiler::TestRunner::Runner.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        }.not_to raise_error
      end
    end

    context "with invalid framework parameter" do
      it "raises an error when framework is an integer" do
        expect {
          Profiler::TestRunner::Runner.start(files: ["spec/fake_spec.rb"], framework: 123)
        }.to raise_error(/framework must be a string or symbol/i)
      end

      it "accepts a symbol framework, as Discovery.files does" do
        allow(Profiler::TestRunner::Runner).to receive(:spawn_async)
        run = Profiler::TestRunner::Runner.start(files: ["spec/fake_spec.rb"], framework: :rspec)
        expect(run.framework).to eq("rspec")
      end

      it "raises an error when framework is an array" do
        expect {
          Profiler::TestRunner::Runner.start(files: ["spec/fake_spec.rb"], framework: ["rspec"])
        }.to raise_error(/framework must be a string or symbol/i)
      end

      it "raises an error when framework is a hash" do
        expect {
          Profiler::TestRunner::Runner.start(files: ["spec/fake_spec.rb"], framework: { name: "rspec" })
        }.to raise_error(/framework must be a string or symbol/i)
      end

      it "raises an error when framework is a boolean" do
        expect {
          Profiler::TestRunner::Runner.start(files: ["spec/fake_spec.rb"], framework: true)
        }.to raise_error(/framework must be a string or symbol/i)
      end
    end
  end
end
