# frozen_string_literal: true

require "spec_helper"

# A Profiler.dump call left in the code returns its argument, whether the profiler is enabled or not.
RSpec.describe "Profiler.dump return value" do
  it "returns the value when the profiler is disabled" do
    Profiler.configuration.enabled = false

    expect(Profiler.dump(42, "answer")).to eq(42)
  end

  it "returns the value when the profiler is enabled, outside a profile" do
    Profiler.configuration.enabled = true

    expect(Profiler.dump(42, "answer")).to eq(42)
  end
end
