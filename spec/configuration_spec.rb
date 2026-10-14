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

  describe "#skip_paths=" do
    it "keeps a list as it is" do
      config.skip_paths = ["/health", %r{\A/assets/}]
      expect(config.skip_paths).to eq(["/health", %r{\A/assets/}])
    end

    it "makes a single pattern a list of one, and nil an empty list" do
      config.skip_paths = "/health"
      expect(config.skip_paths).to eq(["/health"])
      config.skip_paths = nil
      expect(config.skip_paths).to eq([])
    end
  end

  describe "#http_skip_hosts=" do
    it "accepts host names, domain suffixes and Regexps" do
      config.http_skip_hosts = ["api.example.com", ".internal", /\Ametrics\./]
      expect(config.http_skip_hosts).to eq(["api.example.com", ".internal", /\Ametrics\./])
    end

    it "makes a single entry a list of one" do
      config.http_skip_hosts = "api.example.com"
      expect(config.http_skip_hosts).to eq(["api.example.com"])
    end

    context "with an entry that is not a host name" do
      before { allow(Profiler).to receive(:log_warn) }

      it "leaves out a wildcard String with a warning and keeps the other entries" do
        config.http_skip_hosts = ["*.internal", "api.example.com", /\Ametrics\./]

        expect(config.http_skip_hosts).to eq(["api.example.com", /\Ametrics\./])
        expect(Profiler).to have_received(:log_warn)
          .with(/http_skip_hosts: "\*\.internal" is not a host name.*"\.internal".*ignored/).once
      end

      it "leaves out an empty or blank String with a warning" do
        config.http_skip_hosts = ["", " ", "api.example.com"]

        expect(config.http_skip_hosts).to eq(["api.example.com"])
        expect(Profiler).to have_received(:log_warn).with(/http_skip_hosts: "" is not a host name/).once
        expect(Profiler).to have_received(:log_warn).with(/http_skip_hosts: " " is not a host name/).once
      end

      it "leaves out an entry that is neither a String nor a Regexp with a warning" do
        config.http_skip_hosts = [nil, :localhost, "api.example.com"]

        expect(config.http_skip_hosts).to eq(["api.example.com"])
        expect(Profiler).to have_received(:log_warn).with(/http_skip_hosts: nil must be a String or a Regexp/).once
        expect(Profiler).to have_received(:log_warn)
          .with(/http_skip_hosts: :localhost must be a String or a Regexp/).once
      end

      it "never raises, so that a mistake does not stop the application from booting" do
        expect { config.http_skip_hosts = ["*", "", nil, 42] }.not_to raise_error
        expect(config.http_skip_hosts).to eq([])
      end
    end

    it "does not warn about valid entries" do
      allow(Profiler).to receive(:log_warn)
      config.http_skip_hosts = ["api.example.com", ".internal", /\Ametrics\./]

      expect(Profiler).not_to have_received(:log_warn)
    end
  end
end
