# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

# Boots a real, throwaway Rails application in a child process for each case, because what
# is under test is the order of the Rails initializers: the persisted overrides must only be
# applied once the application's own config/initializers have decided `enabled`.
RSpec.describe "Persisted env overrides at boot" do
  let(:secret_value) { "sec08-override-value-must-not-be-logged" }

  def boot_script
    <<~'RUBY'
      require "bundler/setup"
      require "logger"
      require "json"
      require "rails"
      require "action_controller/railtie"
      require "profiler"

      class ProbeApp < Rails::Application
        config.root = ENV.fetch("PROBE_ROOT")
        config.eager_load = false
        config.secret_key_base = "x" * 64
        config.logger = Logger.new(File.join(ENV.fetch("PROBE_ROOT"), "boot.log"))
      end

      ran = []
      Rails::Initializable::Initializer.prepend(Module.new do
        define_method(:run) { |*args| ran << name.to_s; super(*args) }
      end)

      ProbeApp.initialize!
      # A second call in the same process must not log a second warning.
      Profiler.env_override_store.apply_at_boot!(Rails.logger) if ENV["PROBE_CALL_TWICE"]

      puts JSON.generate(
        "applied" => ENV["SEC08_PROBE"],
        "deleted_kept" => ENV["SEC08_DELETED"],
        "enabled" => Profiler.configuration.enabled,
        "ran" => ran,
        "declared" => Profiler::Railtie.initializers.map { |i| i.name.to_s }
      )
    RUBY
  end

  def boot(rails_env:, initializer:, call_twice: false)
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "config", "initializers"))
      File.write(File.join(root, "config", "initializers", "profiler.rb"), initializer)
      FileUtils.mkdir_p(File.join(root, "tmp", "rails-profiler"))
      File.write(
        File.join(root, "tmp", "rails-profiler", "env_overrides.json"),
        JSON.generate(
          "SEC08_PROBE" => { "value" => secret_value, "original" => nil },
          "SEC08_DELETED" => { "value" => Profiler::EnvOverrideStore::DELETED_SENTINEL, "original" => "kept" }
        )
      )
      script = File.join(root, "boot.rb")
      File.write(script, boot_script)

      env = {
        "RAILS_ENV" => rails_env,
        "RACK_ENV" => rails_env,
        "PROBE_ROOT" => root,
        "SEC08_PROBE" => nil,
        "SEC08_DELETED" => "kept",
        "PROBE_CALL_TWICE" => (call_twice ? "1" : nil)
      }
      lib = File.expand_path("../lib", __dir__)
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, script, chdir: root)
      raise "boot failed (#{rails_env}):\n#{err}" unless status.success?

      log = File.read(File.join(root, "boot.log"))
      JSON.parse(out.lines.last).merge("log" => log, "root" => root)
    end
  end

  def warnings(result)
    result["log"].lines.grep(/persisted environment override/)
  end

  context "when the application disables the profiler outside production" do
    let(:initializer) { "Profiler.configure { |c| c.enabled = false }" }
    let(:result) { boot(rails_env: "development", initializer: initializer) }

    it "applies nothing" do
      expect(result["enabled"]).to be(false)
      expect(result["applied"]).to be_nil
      expect(result["deleted_kept"]).to eq("kept")
    end

    it "logs one warning naming the file, the key count and the reason, without any value" do
      result = boot(rails_env: "development", initializer: initializer, call_twice: true)
      lines = warnings(result)
      expect(lines.size).to eq(1)
      expect(lines.first).to include("WARN")
      expect(lines.first).to include("2 persisted environment overrides")
      expect(lines.first).to include(File.join("tmp", "rails-profiler", "env_overrides.json"))
      expect(lines.first).to include("the profiler is disabled")
      expect(lines.first).to include("apply_env_overrides_when_disabled")
      expect(result["log"]).not_to include(secret_value)
    end
  end

  context "when the application enables the profiler in production" do
    let(:result) do
      boot(rails_env: "production", initializer: "Profiler.configure { |c| c.enabled = true }")
    end

    it "applies nothing" do
      expect(result["enabled"]).to be(true)
      expect(result["applied"]).to be_nil
      expect(result["deleted_kept"]).to eq("kept")
    end

    it "applies nothing either with apply_env_overrides_when_disabled set" do
      result = boot(
        rails_env: "production",
        initializer: "Profiler.configure { |c| c.enabled = true; c.apply_env_overrides_when_disabled = true }"
      )
      expect(result["applied"]).to be_nil
    end

    it "logs one warning giving production as the reason, without any value" do
      lines = warnings(result)
      expect(lines.size).to eq(1)
      expect(lines.first).to include("2 persisted environment overrides")
      expect(lines.first).to include("production")
      expect(result["log"]).not_to include(secret_value)
    end
  end

  # An initializer declared without `after:` runs after the one declared before it. Declared
  # below profiler.apply_env_overrides, it would run after the application's initializers too,
  # and profiler.set_configs moved there would overwrite the application's `enabled`.
  describe "initializer order" do
    let(:result) do
      boot(rails_env: "development", initializer: "Profiler.configure { |c| c.enabled = true }")
    end

    it "runs apply_env_overrides after every load_config_initializers, and every other gem initializer before" do
      ran = result["ran"]
      loads = ran.each_index.select { |i| ran[i] == "load_config_initializers" }
      others = result["declared"] - ["profiler.apply_env_overrides"]

      expect(result["declared"].last).to eq("profiler.apply_env_overrides")
      expect(ran.index("profiler.apply_env_overrides")).to be > loads.max
      expect(others.map { |name| ran.index(name) }).to all(be < loads.min)
      expect(others.sort_by { |name| ran.index(name) }).to eq(others)
    end
  end

  context "when the profiler is enabled in development" do
    let(:result) do
      boot(rails_env: "development", initializer: "Profiler.configure { |c| c.enabled = true }")
    end

    it "applies the overrides, deletions included, and logs no warning" do
      expect(result["applied"]).to eq(secret_value)
      expect(result["deleted_kept"]).to be_nil
      expect(warnings(result)).to be_empty
    end
  end

  context "when the profiler is disabled but apply_env_overrides_when_disabled is set" do
    let(:result) do
      boot(rails_env: "development",
           initializer: "Profiler.configure { |c| c.enabled = false; c.apply_env_overrides_when_disabled = true }")
    end

    it "applies the overrides as before" do
      expect(result["applied"]).to eq(secret_value)
      expect(warnings(result)).to be_empty
    end
  end
end
