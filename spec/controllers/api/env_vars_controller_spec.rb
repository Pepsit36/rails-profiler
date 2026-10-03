# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "active_support/core_ext/object/blank"
require "active_support/hash_with_indifferent_access"

# No ActionController harness here (see events_controller_spec.rb): the controller file is
# loaded under a stand-in base class, which is enough to run the logic of #update.
RSpec.describe "Profiler::Api::EnvVarsController#update" do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:store) { Profiler::EnvOverrideStore.new }
  let(:file) { File.join(tmp_dir, "env_overrides.json") }

  let(:controller_class) do
    stub_const("Profiler::ApplicationController", Class.new { def self.skip_before_action(*) = nil })
    stub_const("Profiler::Api", Module.new)
    load File.expand_path("../../../app/controllers/profiler/api/env_vars_controller.rb", __dir__)
    Profiler::Api::EnvVarsController
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.tmp_path = Pathname.new(tmp_dir)
    end
    Profiler.instance_variable_set(:@env_override_store, store)
    # The file of a development machine, shipped with the application.
    File.write(file, JSON.generate("PROFILER_CTRL_A" => { "value" => "dev-override", "original" => "dev-machine-value" }))
    ENV["PROFILER_CTRL_A"] = "deployed-a"
  end

  after do
    ENV.delete("PROFILER_CTRL_A")
    Profiler.instance_variable_set(:@env_override_store, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def update(key, value)
    controller = controller_class.new
    params = ActiveSupport::HashWithIndifferentAccess.new(key: key, value: value)
    controller.define_singleton_method(:params) { params }
    controller.define_singleton_method(:render) { |**_opts| nil }
    controller.update
  end

  context "in production" do
    before { stub_const("Rails", double("Rails", env: ActiveSupport::StringInquirer.new("production"))) }

    it "lets a reset undo a value equal to the file's original, typed back in" do
      update("PROFILER_CTRL_A", "dev-machine-value")
      expect(ENV["PROFILER_CTRL_A"]).to eq("dev-machine-value")

      store.reset("PROFILER_CTRL_A")
      expect(ENV["PROFILER_CTRL_A"]).to eq("deployed-a")
    end
  end

  context "where the overrides are allowed" do
    it "treats a value equal to the original as a reset, as before" do
      update("PROFILER_CTRL_A", "dev-machine-value")
      expect(ENV["PROFILER_CTRL_A"]).to eq("dev-machine-value")
      expect(store.all_overrides).not_to have_key("PROFILER_CTRL_A")
    end
  end
end
