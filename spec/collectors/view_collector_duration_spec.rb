# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/view_collector"

RSpec.describe Profiler::Collectors::ViewCollector, "total duration" do
  let(:profile) { Profiler::Models::Profile.new }
  let(:collector) { described_class.new(profile) }

  after { collector.unsubscribe }

  it "counts the partials a template renders once, inside the template" do
    collector.subscribe
    ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "a/show.erb", layout: nil) do
      ActiveSupport::Notifications.instrument("render_partial.action_view", identifier: "a/_row.erb") { sleep 0.05 }
    end
    collector.collect

    data = profile.collector_data("view")
    template = data[:views].first[:duration]
    expect(data[:partials].first[:duration]).to be <= template
    expect(data[:total_duration]).to be_within(0.01).of(template)
  end
end
