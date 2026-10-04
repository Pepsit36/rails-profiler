# frozen_string_literal: true

require "spec_helper"
require "profiler/cluster/security"

RSpec.describe Profiler::Cluster::Security do
  def configure(**options)
    Profiler.configure do |config|
      options.each { |key, value| config.public_send("#{key}=", value) }
    end
  end

  describe ".slave_url_denial" do
    it "refuses everything by default" do
      expect(described_class.slave_url_denial("https://payment.internal")).to match(/not allowed/)
    end

    it "accepts an allowed origin and any path below it" do
      configure(cluster_allowed_slave_urls: ["https://payment.internal"])

      expect(described_class.slave_url_denial("https://payment.internal")).to be_nil
      expect(described_class.slave_url_denial("https://payment.internal/app")).to be_nil
    end

    it "compares the host whatever its case, and the default port" do
      configure(cluster_allowed_slave_urls: ["HTTPS://Payment.Internal:443"])

      expect(described_class.slave_url_denial("https://payment.internal")).to be_nil
      expect(described_class.slave_url_denial("https://PAYMENT.internal:443/")).to be_nil
      expect(described_class.slave_url_denial("https://payment.internal:8443")).to match(/not allowed/)
    end

    it "compares an IPv6 address written between brackets" do
      configure(cluster_allowed_slave_urls: ["https://[FD00::1]:3001"])

      expect(described_class.slave_url_denial("https://[fd00::1]:3001")).to be_nil
      expect(described_class.slave_url_denial("https://[fd00::2]:3001")).to match(/not allowed/)
    end

    it "compares the path segment by segment" do
      configure(cluster_allowed_slave_urls: ["https://shared.internal/payment"])

      expect(described_class.slave_url_denial("https://shared.internal/payment/v1")).to be_nil
      expect(described_class.slave_url_denial("https://shared.internal/payments")).to match(/not allowed/)
      expect(described_class.slave_url_denial("https://shared.internal/")).to match(/not allowed/)
    end

    it "refuses a path that climbs out of the allowed prefix" do
      configure(cluster_allowed_slave_urls: ["https://shared.internal/payment"])

      expect(described_class.slave_url_denial("https://shared.internal/payment/../admin")).to match(/not a valid/)
      expect(described_class.slave_url_denial("https://shared.internal/payment/%2e%2e/admin")).to match(/not a valid/)
      expect(described_class.slave_url_denial("https://shared.internal/payment/%2F..")).to match(/not a valid/)
    end

    it "refuses a host that only starts like an allowed one, and user info" do
      configure(cluster_allowed_slave_urls: ["https://payment.internal"])

      expect(described_class.slave_url_denial("https://payment.internal.evil.example")).to match(/not allowed/)
      expect(described_class.slave_url_denial("https://payment.internal@evil.example")).to match(/not a valid/)
    end

    it "refuses anything that is not http(s)" do
      configure(cluster_allowed_slave_urls: :any)

      expect(described_class.slave_url_denial("file:///etc/passwd")).to match(/not a valid/)
      expect(described_class.slave_url_denial("gopher://payment.internal")).to match(/not a valid/)
      expect(described_class.slave_url_denial("not a url")).to match(/not a valid/)
    end

    it "wants HTTPS except on a loopback address" do
      configure(cluster_allowed_slave_urls: :any)

      expect(described_class.slave_url_denial("http://payment.internal")).to match(/HTTPS/)
      expect(described_class.slave_url_denial("http://localhost:3001")).to be_nil
      expect(described_class.slave_url_denial("http://127.0.0.2:3001")).to be_nil
      expect(described_class.slave_url_denial("http://[::1]:3001")).to be_nil
    end

    it "accepts plain HTTP with cluster_allow_insecure_http" do
      configure(cluster_allowed_slave_urls: ["http://payment.internal"], cluster_allow_insecure_http: true)
      expect(described_class.slave_url_denial("http://payment.internal")).to be_nil
    end
  end

  describe ".master_url_denial" do
    it "wants HTTPS except on a loopback address" do
      expect(described_class.master_url_denial("https://master.internal")).to be_nil
      expect(described_class.master_url_denial("http://localhost:3000")).to be_nil
      expect(described_class.master_url_denial("http://master.internal")).to match(/HTTPS/)
    end
  end

  describe ".valid_secret?" do
    it "is false when no secret is configured, whatever is presented" do
      expect(described_class.valid_secret?("")).to be(false)
      expect(described_class.valid_secret?(nil)).to be(false)
    end

    it "accepts the configured secret only" do
      secret = "k" * 32
      configure(cluster_secret: secret)

      expect(described_class.valid_secret?(secret)).to be(true)
      expect(described_class.valid_secret?("#{"k" * 31}j")).to be(false)
      expect(described_class.valid_secret?("#{secret}k")).to be(false)
    end

    it "treats a secret shorter than 32 characters, or blank, as missing" do
      configure(cluster_secret: "k" * 31)
      expect(described_class.valid_secret?("k" * 31)).to be(false)
      expect(described_class.configured_secret?).to be(false)
      expect(described_class.outgoing_headers).to eq({})
      expect(described_class.secret_problem).to match(/32 characters/)

      configure(cluster_secret: "  #{" " * 40}\n")
      expect(described_class.valid_secret?(Profiler.configuration.cluster_secret)).to be(false)
      expect(described_class.secret_problem).to match(/No config.cluster_secret/)
    end
  end

  describe ".warn_about_configuration" do
    let(:logger) { instance_double(Logger, warn: nil) }

    it "warns at boot about a weak secret on a cluster node" do
      configure(cluster_master: true, cluster_secret: "short")
      described_class.warn_about_configuration(logger)

      expect(logger).to have_received(:warn).with(/32 characters/)
    end

    it "warns a slave with no secret" do
      configure(master_url: "https://master.internal")
      described_class.warn_about_configuration(logger)

      expect(logger).to have_received(:warn).with(/cluster_secret/)
    end

    it "says nothing outside the cluster, or with a good secret" do
      described_class.warn_about_configuration(logger)
      configure(cluster_master: true, cluster_secret: "k" * 32)
      described_class.warn_about_configuration(logger)

      expect(logger).not_to have_received(:warn)
    end
  end

  describe ".normalized_url" do
    it "rebuilds the URL from its normalized parts" do
      expect(described_class.normalized_url(" HTTPS://Payment.Internal:443/app/ ")).to eq("https://payment.internal/app")
      expect(described_class.normalized_url("http://LOCALHOST:3001")).to eq("http://localhost:3001")
      expect(described_class.normalized_url("https://[FD00::1]:8443/")).to eq("https://[fd00::1]:8443")
      expect(described_class.normalized_url("https://a.internal/x%20y")).to eq("https://a.internal/x%20y")
      expect(described_class.normalized_url("https://a.internal/../b")).to be_nil
    end
  end

  describe ".secret_required?" do
    it "is true by default, and whenever a secret is configured" do
      expect(described_class.secret_required?).to be(true)

      configure(cluster_require_secret: false, cluster_secret: "k" * 32)
      expect(described_class.secret_required?).to be(true)
    end

    it "is false only with cluster_require_secret = false and no secret" do
      configure(cluster_require_secret: false)
      expect(described_class.secret_required?).to be(false)
    end
  end
end
