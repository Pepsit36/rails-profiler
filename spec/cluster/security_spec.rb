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

  describe ".slave_url_denial with Regexp entries" do
    let(:pattern) { %r{\Ahttp://travel-api-[a-z0-9-]+:3000\z} }

    before { configure(cluster_allow_insecure_http: true) }

    it "accepts a URL an anchored pattern matches" do
      configure(cluster_allowed_slave_urls: [pattern])

      expect(described_class.slave_url_denial("http://travel-api-feature-42:3000")).to be_nil
    end

    it "matches the URL as the registry keeps it: lower-case host, no trailing slash" do
      configure(cluster_allowed_slave_urls: [pattern])

      expect(described_class.slave_url_denial("HTTP://Travel-API-feature-42:3000/")).to be_nil
    end

    it "refuses a URL the pattern does not match" do
      configure(cluster_allowed_slave_urls: [pattern])

      expect(described_class.slave_url_denial("http://travel-api-x:3001")).to match(/not allowed/)
      expect(described_class.slave_url_denial("http://travel-api-x:3000/admin")).to match(/not allowed/)
      expect(described_class.slave_url_denial("http://evil/travel-api-x:3000")).to match(/not allowed/)
      expect(described_class.slave_url_denial("http://travel-api-x.evil.example:3000")).to match(/not allowed/)
    end

    it "refuses user info, a query, a fragment or a dot segment before the pattern is tried" do
      configure(cluster_allowed_slave_urls: [%r{\Ahttp://.*\z}])

      expect(described_class.slave_url_denial("http://travel-api-x:3000")).to be_nil
      expect(described_class.slave_url_denial("http://evil@travel-api-x:3000")).to match(/not a valid/)
      expect(described_class.slave_url_denial("http://travel-api-x:3000?x=1")).to match(/not a valid/)
      expect(described_class.slave_url_denial("http://travel-api-x:3000#x")).to match(/not a valid/)
      expect(described_class.slave_url_denial("http://travel-api-x:3000/a/../b")).to match(/not a valid/)
    end

    it "keeps the HTTPS rule: a matching plain HTTP URL to a remote host still needs cluster_allow_insecure_http" do
      configure(cluster_allow_insecure_http: false, cluster_allowed_slave_urls: [pattern])

      expect(described_class.slave_url_denial("http://travel-api-x:3000")).to match(/HTTPS/)
    end

    it "matches the whole URL even when the pattern alternates at the top level" do
      configure(cluster_allowed_slave_urls: [%r{\Ahttp://travel-api-a:3000|http://travel-api-b:3000\z}])

      expect(described_class.slave_url_denial("http://travel-api-a:3000")).to be_nil
      expect(described_class.slave_url_denial("http://travel-api-b:3000")).to be_nil
      expect(described_class.slave_url_denial("http://travel-api-a:3000/admin")).to match(/not allowed/)
    end

    it "refuses an unanchored pattern at configuration time" do
      [%r{travel-api}, %r{\Ahttp://travel-api}, %r{travel-api:3000\z}, %r{^http://travel-api:3000$},
       %r{\Ahttp://travel-api:3000\Z}, %r{\Ahttp://travel-api:3000\\z}].each do |unanchored|
        expect { configure(cluster_allowed_slave_urls: [unanchored]) }
          .to raise_error(ArgumentError, /must start with \\A and end with \\z/)
      end
    end

    it "ignores an unanchored pattern added to the list after configuration" do
      configure(cluster_allowed_slave_urls: [])
      # Once wrapped, this pattern would match the whole URL: only the anchoring check refuses it.
      Profiler.configuration.cluster_allowed_slave_urls << %r{http://travel-api:3000}

      expect(described_class.slave_url_denial("http://travel-api:3000")).to match(/not allowed/)
    end

    it "refuses at configuration time a pattern whose x-mode comment hides the closing \\z" do
      expect { configure(cluster_allowed_slave_urls: [%r{\Ahttp://travel-api-[a-z0-9-]+:3000 # \z}x]) }
        .to raise_error(ArgumentError, /cannot be matched against the whole slave URL/)
    end

    it "accepts an x-mode pattern whose comment ends before the \\z, and applies its options" do
      configure(cluster_allowed_slave_urls: [%r{\Ahttp://travel-api-[a-z0-9-]+ :3000 # worktrees
        \z}x, %r{\Ahttps://PAYMENT\.internal\z}i])

      expect(described_class.slave_url_denial("http://travel-api-x:3000")).to be_nil
      expect(described_class.slave_url_denial("http://travel-api-x:3000/admin")).to match(/not allowed/)
      expect(described_class.slave_url_denial("https://payment.internal")).to be_nil
    end

    it "refuses an anchor that is not at the very start" do
      expect { configure(cluster_allowed_slave_urls: [%r{(\Ahttp://travel-api:3000)\z}]) }
        .to raise_error(ArgumentError, /must start with/)
    end

    it "refuses a path segment holding an encoded backslash, without raising" do
      configure(cluster_allowed_slave_urls: ["http://localhost:3001"])
      expect(described_class.slave_url_denial("http://localhost:3001/a%5Cb")).to match(/not a valid/)

      configure(cluster_allowed_slave_urls: [%r{\Ahttp://localhost:3001(/.*)?\z}])
      expect(described_class.slave_url_denial("http://localhost:3001/a%5Cb")).to match(/not a valid/)
    end

    it "never reads a String as a pattern" do
      configure(cluster_allowed_slave_urls: ['\Ahttp://travel-api-[a-z0-9-]+:3000\z', "/travel-api/", "%r{.*}"])

      expect(described_class.slave_url_denial("http://travel-api-x:3000")).to match(/not allowed/)
    end

    it "mixes URLs and patterns in one list" do
      configure(cluster_allowed_slave_urls: ["https://payment.internal", pattern])

      expect(described_class.slave_url_denial("https://payment.internal/app")).to be_nil
      expect(described_class.slave_url_denial("http://travel-api-x:3000")).to be_nil
      expect(described_class.slave_url_denial("https://other.internal")).to match(/not allowed/)
    end

    it "leaves :any and the empty default unchanged" do
      configure(cluster_allowed_slave_urls: :any)
      expect(described_class.slave_url_denial("http://anything.example:1234")).to be_nil

      configure(cluster_allowed_slave_urls: [])
      expect(described_class.slave_url_denial("http://travel-api-x:3000")).to match(/not allowed/)
    end
  end

  describe ".anchored_pattern?" do
    it "wants an unescaped \\A at the start and \\z at the end of a Regexp" do
      expect(described_class.anchored_pattern?(%r{\Ahttp://a\z})).to be(true)
      expect(described_class.anchored_pattern?(%r{\Ahttp://a\z}i)).to be(true)
      expect(described_class.anchored_pattern?(%r{\A\z})).to be(false)
      expect(described_class.anchored_pattern?(%r{\Ahttp://a\\z})).to be(false)
      expect(described_class.anchored_pattern?('\Ahttp://a\z')).to be(false)
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
