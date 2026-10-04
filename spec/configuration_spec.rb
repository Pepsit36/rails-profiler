# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Configuration do
  subject(:config) { described_class.new }

  describe "#default" do
    it "sets an option the application has not assigned" do
      config.default(:enabled, true)
      config.default(:storage, :file)
      config.default(:track_tests, true)

      expect(config.enabled).to be(true)
      expect(config.storage).to eq(:file)
      expect(config.track_tests).to be(true)
    end

    it "keeps an option the application assigned" do
      config.enabled = false
      config.storage = :memory
      config.track_tests = false

      config.default(:enabled, true)
      config.default(:storage, :file)
      config.default(:track_tests, true)

      expect(config.enabled).to be(false)
      expect(config.storage).to eq(:memory)
      expect(config.track_tests).to be(false)
    end

    it "does not count as an assignment, so a later default still applies" do
      config.default(:enabled, true)
      config.default(:enabled, false)

      expect(config.enabled).to be(false)
    end

    it "rejects an option without a Rails default" do
      expect { config.default(:track_jobs, false) }.to raise_error(ArgumentError, /track_jobs/)
    end
  end
end
