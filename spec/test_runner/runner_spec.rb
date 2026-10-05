# frozen_string_literal: true

require "spec_helper"
require "concurrent"
require "profiler/test_runner/run_store"
require "profiler/test_runner/runner"
require "profiler/env_override_store"
require "fileutils"
require "pathname"

RSpec.describe Profiler::TestRunner::Runner do
  let(:tmpdir) do
    dir = File.realpath(Dir.mktmpdir("profiler_runner_spec"))
    FileUtils.mkdir_p(File.join(dir, "spec/models"))
    FileUtils.mkdir_p(File.join(dir, "test/models"))
    FileUtils.mkdir_p(File.join(dir, "lib/tasks"))
    File.write(File.join(dir, "spec/fake_spec.rb"), "")
    File.write(File.join(dir, "spec/models/user_spec.rb"), "")
    File.write(File.join(dir, "test/models/user_test.rb"), "")
    File.write(File.join(dir, "lib/tasks/not_a_test.rb"), "")
    dir
  end

  before do
    rails_root = Pathname.new(tmpdir)
    rails_stub = Module.new
    rails_stub.define_singleton_method(:root) { rails_root }
    rails_stub.define_singleton_method(:to_s) { "Rails" }
    stub_const("Rails", rails_stub)

    # Reset the singleton run_store
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

  def wait_for_terminal(run, timeout: 5)
    deadline = Time.now + timeout
    until Profiler::TestRunner::RunStore::TERMINAL_STATUSES.include?(run.status)
      sleep 0.05
      raise "Run did not reach terminal status within #{timeout}s" if Time.now > deadline
    end
    run
  end

  describe ".start with a real subprocess" do
    # Stub build_command to run a fast inline Ruby script
    def stub_command(script)
      allow(described_class).to receive(:build_command) do |_files, _framework|
        ["ruby", "-e", script]
      end
    end

    context "when the subprocess exits 0" do
      it "transitions the run to 'passed'" do
        stub_command("puts 'hello'; exit 0")
        run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        wait_for_terminal(run)
        expect(run.status).to eq("passed")
        expect(run.exit_code).to eq(0)
      end

      it "captures stdout output in the run store" do
        stub_command("puts 'hello from test'")
        run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        wait_for_terminal(run)
        expect(run.output_lines.join).to include("hello from test")
      end
    end

    context "when the subprocess exits non-zero" do
      it "transitions the run to 'failed'" do
        stub_command("puts 'failure output'; exit 1")
        run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        wait_for_terminal(run)
        expect(run.status).to eq("failed")
        expect(run.exit_code).to eq(1)
      end
    end

    it "records the pid while running" do
      stub_command("sleep 0.1")
      run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
      # Give the thread time to update pid
      sleep 0.05
      expect(run.pid).not_to be_nil
      wait_for_terminal(run)
    end
  end

  describe ".start file validation" do
    def expect_refused(files, framework: "rspec", message: /Not a discovered test file/)
      expect(described_class).not_to receive(:spawn_async)
      expect { described_class.start(files: files, framework: framework) }
        .to raise_error(Profiler::TestRunner::InvalidFileError, message)
      expect(Profiler::TestRunner.run_store.all).to be_empty
    end

    it "refuses a file under the Rails root that is not a discovered test" do
      expect_refused(["lib/tasks/not_a_test.rb"])
    end

    it "names the refused file in the error" do
      expect { described_class.start(files: ["lib/tasks/not_a_test.rb"], framework: "rspec") }
        .to raise_error(Profiler::TestRunner::InvalidFileError, %r{lib/tasks/not_a_test\.rb})
    end

    it "refuses a path that leaves the Rails root" do
      expect_refused(["../../etc/passwd"])
    end

    it "refuses a path that walks out of the spec directory and back" do
      expect_refused(["spec/../lib/tasks/not_a_test.rb"])
    end

    it "refuses a file that does not exist" do
      expect_refused(["spec/missing_spec.rb"])
    end

    it "refuses a symbolic link in the spec directory pointing outside the discovered tests" do
      File.symlink(File.join(tmpdir, "lib/tasks/not_a_test.rb"), File.join(tmpdir, "spec/models/helper_link.rb"))
      expect_refused(["spec/models/helper_link.rb"])
    end

    it "refuses a discovered-looking symbolic link whose target leaves the Rails root" do
      outside = File.join(File.dirname(tmpdir), "#{File.basename(tmpdir)}_outside.rb")
      File.write(outside, "")
      File.symlink(outside, File.join(tmpdir, "spec/models/escape_spec.rb"))
      expect_refused(["spec/models/escape_spec.rb"])
    ensure
      FileUtils.rm_f(outside)
    end

    it "refuses a test of the other framework" do
      expect_refused(["test/models/user_test.rb"], framework: "rspec")
    end

    it "refuses an empty selection" do
      expect_refused([], message: /No files selected/)
    end

    it "refuses an option disguised as a file" do
      expect_refused(["--require=lib/tasks/not_a_test.rb"])
    end

    it "refuses a path holding a null byte, with an InvalidFileError" do
      expect_refused(["spec/fake_spec.rb\0.rb"])
    end

    it "refuses a path holding a null byte when undiscovered files are allowed" do
      Profiler.configure { |c| c.test_runner_allow_undiscovered_files = true }
      allow(described_class).to receive(:warn)
      expect_refused(["lib/tasks/not_a_test.rb\0"], message: /Not a file under the Rails root/)
    end

    it "refuses the whole selection when one file is not discovered" do
      expect_refused(["spec/fake_spec.rb", "lib/tasks/not_a_test.rb"])
    end

    context "with discovered files" do
      before { allow(described_class).to receive(:spawn_async) }

      it "accepts one file" do
        run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
        expect(run.files).to eq(["spec/fake_spec.rb"])
        expect(described_class).to have_received(:spawn_async).with(run)
      end

      it "accepts several files" do
        run = described_class.start(files: ["spec/fake_spec.rb", "spec/models/user_spec.rb"], framework: "rspec")
        expect(run.files).to eq(["spec/fake_spec.rb", "spec/models/user_spec.rb"])
      end

      it "accepts a line number, and passes it to the command" do
        run = described_class.start(files: ["spec/models/user_spec.rb:12", "spec/fake_spec.rb:3:8"], framework: "rspec")
        expect(run.files).to eq(["spec/models/user_spec.rb:12", "spec/fake_spec.rb:3:8"])
        expect(described_class.send(:build_command, run.files, "rspec"))
          .to include(File.join(tmpdir, "spec/models/user_spec.rb:12"))
      end

      it "accepts a minitest file for minitest" do
        run = described_class.start(files: ["test/models/user_test.rb"], framework: "minitest")
        expect(run.files).to eq(["test/models/user_test.rb"])
      end

      it "accepts a symbolic link to a discovered test" do
        File.symlink(File.join(tmpdir, "spec/fake_spec.rb"), File.join(tmpdir, "spec/models/alias_link.rb"))
        run = described_class.start(files: ["spec/models/alias_link.rb"], framework: "rspec")
        expect(run.files).to eq(["spec/models/alias_link.rb"])
      end
    end
  end

  describe ".start with config.test_runner_allow_undiscovered_files" do
    before do
      Profiler.configure { |c| c.test_runner_allow_undiscovered_files = true }
      allow(described_class).to receive(:spawn_async)
    end

    it "accepts a file under the Rails root that is not a discovered test, with a single warning" do
      expect(described_class).to receive(:warn).with(/test_runner_allow_undiscovered_files/).once

      2.times { described_class.start(files: ["lib/tasks/not_a_test.rb"], framework: "rspec") }

      expect(described_class).to have_received(:spawn_async).twice
    end

    it "still refuses a path that leaves the Rails root" do
      allow(described_class).to receive(:warn)
      expect { described_class.start(files: ["../outside_spec.rb"], framework: "rspec") }
        .to raise_error(Profiler::TestRunner::InvalidFileError, /Not a file under the Rails root/)
      expect(described_class).not_to have_received(:spawn_async)
    end

    it "is off by default" do
      expect(Profiler::Configuration.new.test_runner_allow_undiscovered_files).to be false
    end
  end

  describe ".kill" do
    it "returns false when run is not found" do
      expect(described_class.kill("nonexistent")).to be false
    end

    it "returns false when run is not in running status" do
      run = Profiler::TestRunner.run_store.create(files: [], framework: "rspec")
      Profiler::TestRunner.run_store.update(run.id, status: "passed")
      expect(described_class.kill(run.id)).to be false
    end

    it "kills a running process and sets status to 'killed'" do
      allow(described_class).to receive(:build_command) do |_files, _framework|
        ["ruby", "-e", "sleep 30"]
      end

      run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")

      # Wait until the process is actually running with a pid
      deadline = Time.now + 3
      sleep 0.05 until run.pid || Time.now > deadline

      result = described_class.kill(run.id)
      expect(result).to be true
      expect(run.status).to eq("killed")
    end
  end

  # A page following a run stops at done: done has to come after the last output.
  describe "the end of a run, as a page following it sees it" do
    let(:store) { Profiler::TestRunner.run_store }

    def wait_until(timeout: 10)
      deadline = Time.now + timeout
      sleep 0.05 until yield || Time.now > deadline
    end

    it "ends a killed run only after what the process printed on its way out, and keeps it killed" do
      allow(described_class).to receive(:build_command).and_return(
        ["ruby", "-e", "trap('TERM') { sleep 0.3; puts 'summary on the way out'; exit 1 }; " \
                       "puts 'started'; $stdout.flush; sleep 30"]
      )
      run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
      wait_until { run.output_lines.join.include?("started") }

      expect(described_class.kill(run.id)).to be true
      expect(run.status).to eq("killed")
      expect(store.read_output(run.id, position: 0)[:finished]).to be(false)

      wait_until { store.read_output(run.id, position: 0)[:finished] }
      expect(store.read_output(run.id, position: 0)[:chunks].join).to include("summary on the way out")
      wait_until { run.exit_code }
      expect(run.status).to eq("killed")
    end

    it "gives a run that could not start its error before its error status" do
      allow(described_class).to receive(:build_command).and_raise("no such command")
      seen = []
      allow(store).to receive(:update).and_wrap_original do |original, id, **attrs|
        seen << [:status, attrs[:status]] if attrs[:status]
        original.call(id, **attrs)
      end
      allow(store).to receive(:append_output).and_wrap_original do |original, *args|
        seen << [:output, args.last]
        original.call(*args)
      end

      run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
      wait_until { store.read_output(run.id, position: 0)[:finished] }

      output_at = seen.index { |kind, text| kind == :output && text.include?("[Profiler] Error: no such command") }
      expect(output_at).not_to be_nil
      expect(output_at).to be < seen.index([:status, "error"])
      expect(store.read_output(run.id, position: 0)[:chunks].join).to include("no such command")
    end
  end

  describe ".build_env" do
    it "sets RAILS_ENV to 'test'" do
      env = described_class.send(:build_env)
      expect(env["RAILS_ENV"]).to eq("test")
    end

    it "sets RACK_ENV to 'test'" do
      env = described_class.send(:build_env)
      expect(env["RACK_ENV"]).to eq("test")
    end

    it "does not allow overrides of blocked env keys" do
      allow(Profiler).to receive(:env_override_store).and_return(
        instance_double(Profiler::EnvOverrideStore, all_overrides: {
          "RAILS_ENV" => { "value" => "production" },
          "DATABASE_URL" => { "value" => "postgres://evil" }
        })
      )
      env = described_class.send(:build_env)
      expect(env["RAILS_ENV"]).to eq("test")
      expect(env["DATABASE_URL"]).to eq("postgres://evil").or(be_nil)
      # RAILS_ENV stays test regardless
      expect(env["RAILS_ENV"]).to eq("test")
    end

    context "with overrides of variables that make the test process load other code" do
      let(:overrides) do
        {
          "RUBYOPT" => { "value" => "-r./lib/tasks/not_a_test.rb" },
          "RUBYLIB" => { "value" => "lib/tasks" },
          "SPEC_OPTS" => { "value" => "--require ./lib/tasks/not_a_test.rb" },
          "BUNDLE_GEMFILE" => { "value" => "lib/tasks/Gemfile" },
          "BUNDLE_BIN_PATH" => { "value" => "lib/tasks/bundle" },
          "GEM_HOME" => { "value" => "lib/tasks/gems" },
          "GEM_PATH" => { "value" => "lib/tasks/gems" },
          "LD_PRELOAD" => { "value" => "lib/tasks/evil.so" },
          "LD_LIBRARY_PATH" => { "value" => "lib/tasks" },
          "PATH" => { "value" => "lib/tasks" },
          "NODE_OPTIONS" => { "value" => "--require ./lib/tasks/evil.js" },
          "rubyopt" => { "value" => "-r./lib/tasks/not_a_test.rb" },
          "MY_FEATURE_FLAG" => { "value" => "enabled" }
        }
      end

      before do
        # The store records the value each variable had before its override.
        with_originals = overrides.to_h { |key, entry| [key, entry.merge("original" => ENV[key])] }
        allow(Profiler).to receive(:env_override_store).and_return(
          instance_double(Profiler::EnvOverrideStore, all_overrides: with_originals)
        )
        allow(described_class).to receive(:warn)
      end

      it "does not pass those overrides, and keeps the values the process inherited" do
        env = described_class.send(:build_env)

        (overrides.keys - ["MY_FEATURE_FLAG"]).each do |key|
          expect(env[key]).to eq(ENV[key]), "expected the override of #{key} to be left out"
        end
        expect(env["PATH"]).to eq(ENV["PATH"])
        expect(env["MY_FEATURE_FLAG"]).to eq("enabled")
      end

      it "warns once, naming the variables left out without their values" do
        2.times { described_class.send(:build_env) }

        expect(described_class).to have_received(:warn).once
        expect(described_class).to have_received(:warn) do |message|
          expect(message).to include("RUBYOPT", "SPEC_OPTS", "BUNDLE_GEMFILE", "LD_PRELOAD", "PATH", "NODE_OPTIONS")
          expect(message).not_to include("not_a_test.rb")
          expect(message).not_to include("MY_FEATURE_FLAG")
        end
      end
    end

    it "applies non-blocked env var overrides" do
      allow(Profiler).to receive(:env_override_store).and_return(
        instance_double(Profiler::EnvOverrideStore, all_overrides: {
          "MY_FEATURE_FLAG" => { "value" => "enabled" }
        })
      )
      env = described_class.send(:build_env)
      expect(env["MY_FEATURE_FLAG"]).to eq("enabled")
    end
  end
end
