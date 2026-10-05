# frozen_string_literal: true

require "spec_helper"

# Without stackprof the function profiler is off (Profiler.function_profiling_tracepoint_fallback)
# and its data says reason: "stackprof_missing". The front end has no test runner: these
# examples read the Timeline tab's source.
RSpec.describe "Front end of the function profiler without stackprof" do
  source = File.read(File.expand_path("../app/assets/typescript/profiler/components/dashboard/tabs/FlameGraphTab.tsx", __dir__))
  types = File.read(File.expand_path("../app/assets/typescript/profiler/dashboard/types.ts", __dir__))

  it "knows the reason the collector gives" do
    expect(types).to match(/reason\?: 'stackprof_missing'/)
    expect(source).to include("data?.reason === 'stackprof_missing'")
  end

  it "says what to do instead of offering a toggle that changes nothing" do
    expect(source).to include("gem \"stackprof\"")
    expect(source).to include("Profiler.function_profiling_tracepoint_fallback = true")
    expect(source).to match(/functionProfileData\?\.reason === 'stackprof_missing' \? true/)
  end

  it "no longer says that sampling is on by default whatever the Gemfile" do
    expect(source).not_to match(/stackprof[^<]*enabled by default/)
  end
end
