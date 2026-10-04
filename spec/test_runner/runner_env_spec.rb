# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "pathname"
require "concurrent"
require "profiler/test_runner/runner"
require "profiler/env_override_store"
require "profiler/mcp/tools/set_env_var"
require "profiler/mcp/tools/delete_env_var"

# The environment of the test process, with the overrides written the way the real callers write
# them: the store first, then ENV of the web process itself (EnvVarsController#update, the MCP tools
# set_env_var and delete_env_var, and EnvOverrideStore#apply! at boot).
RSpec.describe Profiler::TestRunner::Runner, ".build_env with real overrides" do
  let(:tmp_path) { Pathname.new(Dir.mktmpdir("profiler_runner_env_spec")) }

  around do |example|
    saved = ENV.to_h
    example.run
  ensure
    ENV.replace(saved)
  end

  before do
    Profiler.configure { |c| c.tmp_path = tmp_path }
    Profiler.instance_variable_set(:@env_override_store, nil)
    # The warning goes to Rails.logger when Rails is loaded (the request specs load it).
    hide_const("Rails")
    allow(described_class).to receive(:warn)
  end

  after do
    Profiler.instance_variable_set(:@env_override_store, nil)
    described_class.reset_warnings!
    FileUtils.rm_rf(tmp_path)
  end

  def set_env(key, value)
    Profiler::MCP::Tools::SetEnvVar.call("key" => key, "value" => value)
  end

  def build_env
    described_class.send(:build_env)
  end

  it "gives the test process the original value of an overridden code-loading variable" do
    ENV["SPEC_OPTS"] = "--format documentation"
    set_env("SPEC_OPTS", "--require ./lib/tasks/not_a_test.rb")
    expect(ENV["SPEC_OPTS"]).to eq("--require ./lib/tasks/not_a_test.rb")

    expect(build_env["SPEC_OPTS"]).to eq("--format documentation")
  end

  it "removes an overridden code-loading variable that the process did not have" do
    ENV.delete("BUNDLE_GEMFILE")
    set_env("BUNDLE_GEMFILE", "lib/tasks/Gemfile")
    ENV.delete("RUBYOPT")
    set_env("RUBYOPT", "-r./lib/tasks/not_a_test.rb")

    env = build_env

    # nil unsets the variable in the child: IO.popen merges the hash into the inherited ENV.
    expect(env).to include("BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil)
  end

  it "restores a code-loading variable deleted through the profiler" do
    ENV["NODE_OPTIONS"] = "--max-old-space-size=512"
    Profiler::MCP::Tools::DeleteEnvVar.call("key" => "NODE_OPTIONS")
    expect(ENV).not_to have_key("NODE_OPTIONS")

    expect(build_env["NODE_OPTIONS"]).to eq("--max-old-space-size=512")
  end

  it "gives the test process the original value of the blocked keys" do
    ENV["DATABASE_URL"] = "postgres://localhost/app_test"
    set_env("DATABASE_URL", "postgres://elsewhere/prod")
    ENV.delete("SECRET_KEY_BASE")
    set_env("SECRET_KEY_BASE", "overridden")

    env = build_env

    expect(env["DATABASE_URL"]).to eq("postgres://localhost/app_test")
    expect(env).to include("SECRET_KEY_BASE" => nil)
  end

  it "leaves out the overrides that make a bash shim run a command" do
    {
      "BASH_FUNC_exec%%" => "() { touch /tmp/pwned; }",
      "BASH_ENV" => "lib/tasks/evil.sh",
      "SHELLOPTS" => "xtrace",
      "PS4" => "$(touch /tmp/pwned)",
      "RBENV_DEBUG" => "1",
      "ENV" => "lib/tasks/evil.sh",
      "rubyopt" => "-r./lib/tasks/not_a_test.rb",
      "GIT_SSH_COMMAND" => "touch /tmp/pwned",
      "BOOTSNAP_CACHE_DIR" => "lib/tasks",
      "PYTHONSTARTUP" => "lib/tasks/evil.py",
      "PERL5OPT" => "-Mevil"
    }.each do |key, value|
      ENV.delete(key)
      set_env(key, value)
    end

    env = build_env

    %w[BASH_FUNC_exec%% BASH_ENV SHELLOPTS PS4 RBENV_DEBUG ENV rubyopt GIT_SSH_COMMAND
       BOOTSNAP_CACHE_DIR PYTHONSTARTUP PERL5OPT].each do |key|
      expect(env.fetch(key, :absent)).to be_nil, "expected the override of #{key} to be left out"
    end
  end

  it "does not let a left-out override reach the started process" do
    root = Dir.mktmpdir("profiler_runner_env_root")
    FileUtils.mkdir_p(File.join(root, "spec"))
    File.write(File.join(root, "spec/fake_spec.rb"), "")
    rails_root = Pathname.new(root)
    stub_const("Rails", Module.new.tap { |m| m.define_singleton_method(:root) { rails_root } })
    allow(described_class).to receive(:build_command) do
      ["ruby", "-e", 'print [ENV.fetch("SPEC_OPTS", "<unset>"), ENV.fetch("PS4", "<unset>"), ENV["MY_FEATURE_FLAG"]].join("|")']
    end
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
    ENV.delete("SPEC_OPTS")
    ENV.delete("PS4")
    set_env("SPEC_OPTS", "--require ./lib/tasks/not_a_test.rb")
    set_env("PS4", "$(touch /tmp/pwned)")
    set_env("MY_FEATURE_FLAG", "enabled")

    run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
    deadline = Time.now + 10
    sleep 0.05 until Profiler::TestRunner::RunStore::TERMINAL_STATUSES.include?(run.status) || Time.now > deadline

    expect(run.output_lines.join).to eq("<unset>|<unset>|enabled")
  ensure
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
    FileUtils.rm_rf(root) if root
  end

  it "still passes the other overrides" do
    set_env("MY_FEATURE_FLAG", "enabled")

    expect(build_env["MY_FEATURE_FLAG"]).to eq("enabled")
  end

  it "names the variables left out once, without their values" do
    ENV.delete("RUBYOPT")
    set_env("RUBYOPT", "-r./lib/tasks/not_a_test.rb")

    2.times { build_env }

    expect(described_class).to have_received(:warn).once
    expect(described_class).to have_received(:warn).with(
      satisfy { |message| message.include?("RUBYOPT") && !message.include?("not_a_test.rb") }
    )
  end
end
