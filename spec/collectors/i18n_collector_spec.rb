# frozen_string_literal: true

require "spec_helper"
require "i18n"
require "profiler/collectors/i18n_collector"

RSpec.describe Profiler::Collectors::I18nCollector do
  let(:profile) { build_profile }
  let(:collector) { described_class.new(profile) }

  before { collector.subscribe }

  after { Thread.current[:profiler_i18n_collector] = nil }

  describe "the I18n patch once installed" do
    it "returns the default of I18n.t called without a positional key" do
      expect(I18n.t(default: "x")).to eq("x")
    end

    it "returns the default of I18n.translate called without a positional key" do
      expect(I18n.translate(default: "x")).to eq("x")
    end

    it "still records the lookups made with a key" do
      I18n.t("profiler.spec.absent", default: "fallback")
      collector.collect

      expect(profile.collector_data(collector.name)[:lookups].map { |l| l[:key] }).to eq(["profiler.spec.absent"])
    end
  end
end
