# frozen_string_literal: true

require "spec_helper"
require "rails"
require "profiler/railtie"

RSpec.describe "Profiler::Railtie console block" do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.track_console = true
    end
  end

  def run_console_block
    Profiler::Railtie.instance.send(:run_console_blocks, nil)
  end

  it "does not raise when IRB is not loaded" do
    hide_const("IRB")
    expect { run_console_block }.not_to raise_error
  end

  it "instruments IRB when it is loaded" do
    stub_const("IRB::Context", Class.new)
    run_console_block
    expect(IRB::Context.ancestors).to include(Profiler::Instrumentation::IrbInstrumentation)
  end

  it "instruments Pry when it is loaded" do
    hide_const("IRB")
    stub_const("Pry", Class.new)
    run_console_block
    expect(Pry.ancestors).to include(Profiler::Instrumentation::PryInstrumentation)
  end

  it "instruments nothing when track_console is off" do
    Profiler.configure { |c| c.track_console = false }
    stub_const("Pry", Class.new)
    run_console_block
    expect(Pry.ancestors).not_to include(Profiler::Instrumentation::PryInstrumentation)
  end
end
