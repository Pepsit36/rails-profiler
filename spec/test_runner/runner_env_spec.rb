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
# set_env_var and delete_env_var, and EnvOverrideStore#apply! at boot). Profiler::BOOT_ENV stands
# for the environment the shell gave the process, captured when the gem was loaded.
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

  # The shell environment of the process: the current one, with these changes.
  def boot_with(changes = {})
    stub_const("Profiler::BOOT_ENV", ENV.to_h.merge(changes).compact.freeze)
  end

  def run_and_read(script)
    root = Dir.mktmpdir("profiler_runner_env_root")
    FileUtils.mkdir_p(File.join(root, "spec"))
    File.write(File.join(root, "spec/fake_spec.rb"), "")
    rails_root = Pathname.new(root)
    stub_const("Rails", Module.new.tap { |m| m.define_singleton_method(:root) { rails_root } })
    allow(described_class).to receive(:build_command) { ["ruby", "-e", script] }
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)

    run = described_class.start(files: ["spec/fake_spec.rb"], framework: "rspec")
    deadline = Time.now + 10
    sleep 0.05 until Profiler::TestRunner::RunStore::TERMINAL_STATUSES.include?(run.status) || Time.now > deadline
    run.output_lines.join
  ensure
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
    FileUtils.rm_rf(root) if root
  end

  it "gives the test process the shell value of an overridden code-loading variable" do
    boot_with("SPEC_OPTS" => "--format documentation")
    ENV["SPEC_OPTS"] = "--format documentation"
    set_env("SPEC_OPTS", "--require ./lib/tasks/not_a_test.rb")
    expect(ENV["SPEC_OPTS"]).to eq("--require ./lib/tasks/not_a_test.rb")

    expect(build_env["SPEC_OPTS"]).to eq("--format documentation")
  end

  it "leaves out an overridden code-loading variable that the shell did not set" do
    boot_with("BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil)
    set_env("BUNDLE_GEMFILE", "lib/tasks/Gemfile")
    set_env("RUBYOPT", "-r./lib/tasks/not_a_test.rb")

    env = build_env

    expect(env).not_to have_key("BUNDLE_GEMFILE")
    expect(env).not_to have_key("RUBYOPT")
  end

  it "restores a code-loading variable deleted through the profiler" do
    boot_with("NODE_OPTIONS" => "--max-old-space-size=512")
    Profiler::MCP::Tools::DeleteEnvVar.call("key" => "NODE_OPTIONS")
    expect(ENV).not_to have_key("NODE_OPTIONS")

    expect(build_env["NODE_OPTIONS"]).to eq("--max-old-space-size=512")
  end

  it "gives the test process the shell value of the blocked keys" do
    boot_with("DATABASE_URL" => "postgres://localhost/app_test", "SECRET_KEY_BASE" => nil)
    set_env("DATABASE_URL", "postgres://elsewhere/prod")
    set_env("SECRET_KEY_BASE", "overridden")

    env = build_env

    expect(env["DATABASE_URL"]).to eq("postgres://localhost/app_test")
    expect(env).not_to have_key("SECRET_KEY_BASE")
  end

  it "uses the shell value of this boot, not the original recorded by an older one" do
    ENV["DATABASE_URL"] = "postgres://localhost/recorded_days_ago"
    set_env("DATABASE_URL", "postgres://elsewhere/prod")
    boot_with("DATABASE_URL" => "postgres://localhost/current_shell")

    expect(build_env["DATABASE_URL"]).to eq("postgres://localhost/current_shell")
  end

  it "leaves out the overrides that make a bash shim run a command" do
    keys = {
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
      "PERL5OPT" => "-Mevil",
      "GEMRC" => "lib/tasks/gemrc",
      "GEM_HOME" => "lib/tasks/gems",
      "NODE_OPTIONS" => "--require ./lib/tasks/evil.js",
      "NODE_PATH" => "lib/tasks"
    }
    boot_with(keys.transform_values { nil })
    keys.each { |key, value| set_env(key, value) }

    env = build_env

    keys.each_key do |key|
      expect(env).not_to have_key(key), "expected the override of #{key} to be left out"
    end
  end

  it "passes the overrides whose name only starts like a code-loading one" do
    set_env("GEMINI_API_KEY", "key")
    set_env("NODE_ENV", "test")

    env = build_env

    expect(env["GEMINI_API_KEY"]).to eq("key")
    expect(env["NODE_ENV"]).to eq("test")
  end

  context "when the store lost an entry that ENV still carries" do
    # EnvOverrideStore#set reads then writes the file without a lock: concurrent writes lose
    # entries, and ENV keeps the override with nothing in the store to say it is one.
    before do
      boot_with("RUBYOPT" => nil, "BASH_FUNC_exec%%" => nil, "SPEC_OPTS" => nil)
      ENV["RUBYOPT"] = "-r./lib/tasks/not_a_test.rb"
      ENV["BASH_FUNC_exec%%"] = "() { touch /tmp/pwned; }"
      ENV["SPEC_OPTS"] = "--require ./lib/tasks/not_a_test.rb"
      expect(Profiler.env_override_store.all_overrides).to be_empty
    end

    it "builds the environment from the shell values" do
      env = build_env

      expect(env).not_to have_key("RUBYOPT")
      expect(env).not_to have_key("BASH_FUNC_exec%%")
      expect(env).not_to have_key("SPEC_OPTS")
    end

    it "does not let the override reach the started process" do
      output = run_and_read('print [ENV.fetch("SPEC_OPTS", "<unset>"), ENV.fetch("BASH_FUNC_exec%%", "<unset>")].join("|")')

      expect(output).to eq("<unset>|<unset>")
    end
  end

  it "leaves out every code-loading override after a burst of concurrent writes" do
    keys = %w[BASH_FUNC_exec%% RUBYOPT SPEC_OPTS BASH_ENV PS4 SHELLOPTS RBENV_DEBUG BUNDLE_GEMFILE GEM_HOME]
    boot_with(keys.to_h { |key| [key, nil] })

    keys.map { |key| Thread.new { set_env(key, "lib/tasks/not_a_test.rb") } }.each(&:join)

    env = build_env
    keys.each { |key| expect(env).not_to have_key(key), "expected #{key} to be left out" }
  end

  it "does not let a left-out override reach the started process" do
    boot_with("SPEC_OPTS" => nil, "PS4" => nil)
    set_env("SPEC_OPTS", "--require ./lib/tasks/not_a_test.rb")
    set_env("PS4", "$(touch /tmp/pwned)")
    set_env("MY_FEATURE_FLAG", "enabled")

    output = run_and_read('print [ENV.fetch("SPEC_OPTS", "<unset>"), ENV.fetch("PS4", "<unset>"), ENV["MY_FEATURE_FLAG"]].join("|")')

    expect(output).to eq("<unset>|<unset>|enabled")
  end

  it "still passes the other overrides" do
    set_env("MY_FEATURE_FLAG", "enabled")

    expect(build_env["MY_FEATURE_FLAG"]).to eq("enabled")
  end

  it "unsets a variable deleted through the profiler" do
    boot_with("MY_FEATURE_FLAG" => "enabled")
    Profiler::MCP::Tools::DeleteEnvVar.call("key" => "MY_FEATURE_FLAG")

    expect(build_env).not_to have_key("MY_FEATURE_FLAG")
  end

  it "names the variables left out once, without their values" do
    boot_with("RUBYOPT" => nil)
    set_env("RUBYOPT", "-r./lib/tasks/not_a_test.rb")

    2.times { build_env }

    expect(described_class).to have_received(:warn).once
    expect(described_class).to have_received(:warn).with(
      satisfy { |message| message.include?("RUBYOPT") && !message.include?("not_a_test.rb") }
    )
  end
end
