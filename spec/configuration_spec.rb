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

    it "refuses a wildcard String, which is not a host name" do
      expect { config.http_skip_hosts = ["*.internal"] }
        .to raise_error(ArgumentError, /http_skip_hosts: "\*\.internal" is not a host name.*"\.internal"/)
    end

    it "refuses an empty String, which would match no host" do
      expect { config.http_skip_hosts = [" "] }.to raise_error(ArgumentError, /http_skip_hosts: " " is not a host name/)
    end

    it "refuses an entry that is neither a String nor a Regexp" do
      expect { config.http_skip_hosts = [:localhost] }
        .to raise_error(ArgumentError, /http_skip_hosts: :localhost must be a String or a Regexp/)
    end

    it "keeps the former value when it refuses the new one" do
      config.http_skip_hosts = ["api.example.com"]
      expect { config.http_skip_hosts = ["*"] }.to raise_error(ArgumentError)
      expect(config.http_skip_hosts).to eq(["api.example.com"])
    end
  end
end
