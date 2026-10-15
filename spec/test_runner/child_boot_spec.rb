# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"
require "profiler/test_runner/runner"
require "profiler/env_override_store"

# The test process the runner starts is the same application: it boots with the same
# tmp/rails-profiler/env_overrides.json. Its initializers must not replay the overrides that
# build_env left out or blocked.
RSpec.describe Profiler::TestRunner::Runner, "test process boot" do
  let(:root) { File.realpath(Dir.mktmpdir("profiler_child_boot_spec")) }
  let(:tmp_path) { Pathname.new(File.join(root, "tmp", "rails-profiler")) }
  let(:boot_script) do
    <<~RUBY
      require "bundler/setup"
      require "json"
      require "logger"
      require "rails"
      require "action_controller/railtie"
      require "profiler"
      require "profiler/railtie"
      require "profiler/engine"

      class ChildApp < Rails::Application
        config.root = #{root.inspect}
        config.eager_load = false
        config.logger = Logger.new(nil)
        config.secret_key_base = "a" * 64
      end
      ChildApp.initialize!

      print JSON.generate(ENV.to_h.slice("SPEC_OPTS", "DATABASE_URL", "MY_FEATURE_FLAG"))
    RUBY
  end

  before do
    FileUtils.mkdir_p(tmp_path)
    File.write(tmp_path.join("env_overrides.json"), JSON.generate(
      "SPEC_OPTS" => { "value" => "--require ./lib/tasks/not_a_test.rb", "original" => nil },
      "DATABASE_URL" => { "value" => "postgres://elsewhere/prod", "original" => nil },
      "MY_FEATURE_FLAG" => { "value" => "enabled", "original" => nil }
    ))
    Profiler.configure { |c| c.tmp_path = tmp_path }
    Profiler.instance_variable_set(:@env_override_store, nil)
    hide_const("Rails")
    allow(Profiler).to receive(:log_warn)
    stub_const("Profiler::BOOT_ENV", ENV.to_h.except("SPEC_OPTS", "DATABASE_URL", "MY_FEATURE_FLAG").freeze)
  end

  after do
    Profiler.instance_variable_set(:@env_override_store, nil)
    described_class.reset_warnings!
    FileUtils.rm_rf(root)
  end

  def boot(env)
    script = File.join(root, "boot.rb")
    File.write(script, boot_script)
    output, status = Open3.capture2e(env, "ruby", "-I", File.expand_path("../../lib", __dir__), script,
                                     unsetenv_others: true, chdir: root)
    expect(status).to be_success, output
    JSON.parse(output.lines.last)
  end

  it "does not replay the left-out and blocked overrides" do
    env = boot(described_class.send(:build_env))

    expect(env).not_to have_key("SPEC_OPTS")
    expect(env).not_to have_key("DATABASE_URL")
    expect(env["MY_FEATURE_FLAG"]).to eq("enabled")
  end

  # SPEC_OPTS and DATABASE_URL are refused by EnvKeyPolicy everywhere now, apply! included, so they
  # no longer show what the marker does. A key the policy allows does: the test process keeps the
  # value build_env gave it even when the file says otherwise by the time it boots, and only the
  # marker stops its EnvOverrideStore#apply! from replaying the file over it.
  context "when the file changes between build_env and the test process boot" do
    def rewrite_flag(value)
      File.write(tmp_path.join("env_overrides.json"),
                 JSON.generate("MY_FEATURE_FLAG" => { "value" => value, "original" => nil }))
    end

    it "keeps the environment build_env gave the test process" do
      env = described_class.send(:build_env)
      expect(env).to include("MY_FEATURE_FLAG" => "enabled", Profiler::EnvKeyPolicy::TEST_RUNNER_CHILD_ENV => "1")
      rewrite_flag("from_the_file")

      expect(boot(env)).to eq("MY_FEATURE_FLAG" => "enabled")
    end

    # The witness: the same environment without the marker, and the application replays the file.
    it "replays the file in a process booted without the marker" do
      env = described_class.send(:build_env).except(Profiler::EnvKeyPolicy::TEST_RUNNER_CHILD_ENV)
      rewrite_flag("from_the_file")

      expect(boot(env)).to eq("MY_FEATURE_FLAG" => "from_the_file")
    end
  end
end
