# frozen_string_literal: true

require "spec_helper"
require "profiler/cluster/slave_registry"
require "profiler/cluster/slave_proxy"

RSpec.describe Profiler::Cluster::SlaveProxy do
  before do
    # A master that lets these slaves through: secret configured, URLs allowed.
    Profiler.configure do |config|
      config.cluster_secret = "spec-secret-0123456789abcdefghijklmnop"
      config.cluster_allowed_slave_urls = %w[http://payment:3001 http://trailing:3001]
      config.cluster_allow_insecure_http = true
    end
    Profiler.instance_variable_set(:@slave_registry, Profiler::Cluster::SlaveRegistry.new)
    Profiler.slave_registry.register(name: "payment", url: "http://payment:3001")
  end

  subject(:proxy) { described_class.new("payment") }

  describe ".new" do
    it "raises for an unknown slave" do
      expect { described_class.new("ghost") }.to raise_error(Profiler::Error, /Unknown slave/)
    end

    it "raises when the slave is offline" do
      entry = Profiler.slave_registry.register(name: "stale", url: "http://stale:3001")
      entry.last_heartbeat_at = Time.now - 999
      expect { described_class.new("stale") }.to raise_error(Profiler::Error, /offline/)
    end

    it "strips a trailing slash from the slave url" do
      Profiler.slave_registry.register(name: "trailing", url: "http://trailing:3001/")
      expect(described_class.new("trailing").instance_variable_get(:@base_url)).to eq("http://trailing:3001")
    end
  end

  describe "#list" do
    # Regression: the proxy must mirror Profiler.storage.list, which returns ALL
    # profile types. Querying only http would make query_jobs/tests/console via a
    # slave silently return nothing.
    it "requests all profile types" do
      allow(proxy).to receive(:get_json).and_return({ "profiles" => [] })
      proxy.list(limit: 10)
      expect(proxy).to have_received(:get_json).with(
        "/_profiler/api/profiles", hash_including(all_types: true)
      )
    end

    it "maps the response into Profile objects of any type" do
      allow(proxy).to receive(:get_json).and_return(
        "profiles" => [
          {
            "token" => "job1", "profile_type" => "job", "path" => "/work",
            "method" => "JOB", "status" => 200, "duration" => 1.0,
            "started_at" => Time.now.iso8601
          }
        ]
      )
      result = proxy.list(limit: 10)
      expect(result.first).to be_a(Profiler::Models::Profile)
      expect(result.first.profile_type).to eq("job")
    end
  end

  describe "#load" do
    it "returns nil when the slave has no such profile" do
      allow(proxy).to receive(:get_json).and_return("error" => "Profile not found")
      expect(proxy.load(SecureRandom.hex(16))).to be_nil
    end

    it "builds a Profile from the slave payload" do
      allow(proxy).to receive(:get_json).and_return(
        "token" => "0a1b2c3d4e5f60718293a4b5c6d7e8f9", "profile_type" => "http", "path" => "/x",
        "method" => "GET", "status" => 200, "duration" => 2.0,
        "started_at" => Time.now.iso8601
      )
      expect(proxy.load("0a1b2c3d4e5f60718293a4b5c6d7e8f9")).to be_a(Profiler::Models::Profile)
    end
  end

  describe "#find_by_parent" do
    it "requests profiles filtered by parent_token with all_types" do
      allow(proxy).to receive(:get_json).and_return({ "profiles" => [] })
      proxy.find_by_parent("9f8e7d6c5b4a39281706f5e4d3c2b1a0")
      expect(proxy).to have_received(:get_json).with(
        "/_profiler/api/profiles", hash_including(parent_token: "9f8e7d6c5b4a39281706f5e4d3c2b1a0", all_types: true)
      )
    end

    it "returns an array of Profile objects" do
      allow(proxy).to receive(:get_json).and_return(
        "profiles" => [
          {
            "token" => "job1", "profile_type" => "job", "path" => "/work",
            "method" => "JOB", "status" => 200, "duration" => 1.0,
            "started_at" => Time.now.iso8601
          }
        ]
      )
      result = proxy.find_by_parent("9f8e7d6c5b4a39281706f5e4d3c2b1a0")
      expect(result.size).to eq(1)
      expect(result.first).to be_a(Profiler::Models::Profile)
      expect(result.first.profile_type).to eq("job")
    end

    it "returns an empty array when no children exist" do
      allow(proxy).to receive(:get_json).and_return({ "profiles" => [] })
      expect(proxy.find_by_parent("no-children")).to eq([])
    end
  end

  describe "timeout overrides" do
    it "uses custom open/read timeouts when provided" do
      proxy_with_timeouts = described_class.new("payment", open_timeout: 2, read_timeout: 3)
      expect(proxy_with_timeouts.instance_variable_get(:@open_timeout)).to eq(2)
      expect(proxy_with_timeouts.instance_variable_get(:@read_timeout)).to eq(3)
    end

    it "falls back to constants when no overrides given" do
      expect(proxy.instance_variable_get(:@open_timeout)).to eq(Profiler::Cluster::SlaveProxy::OPEN_TIMEOUT)
      expect(proxy.instance_variable_get(:@read_timeout)).to eq(Profiler::Cluster::SlaveProxy::READ_TIMEOUT)
    end
  end

  # The paths the master takes when the slave misbehaves: Net::HTTP.start is the one seam, so the
  # answers (and the failures) are the ones a real slave could give.
  describe "a slave that misbehaves" do
    def answer(code, body)
      response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, body)
      response
    end

    def stub_start(response = nil, &block)
      allow(Net::HTTP).to receive(:start) do |*_args, **_opts, &_blk|
        block ? block.call : response
      end
    end

    it "lets a timeout reach the caller" do
      stub_start { raise Net::ReadTimeout }

      expect { proxy.get_json("/_profiler/api/profiles") }.to raise_error(Net::ReadTimeout)
    end

    it "lets a refused connection reach the caller" do
      stub_start { raise Errno::ECONNREFUSED }

      expect { proxy.list }.to raise_error(Errno::ECONNREFUSED)
    end

    it "passes its timeouts to Net::HTTP" do
      slow = described_class.new("payment", open_timeout: 1, read_timeout: 2)
      stub_start(answer(200, "{}"))

      slow.get_json("/_profiler/api/profiles")

      expect(Net::HTTP).to have_received(:start).with("payment", 3001, hash_including(open_timeout: 1, read_timeout: 2))
    end

    it "keeps a body that is not JSON under raw" do
      stub_start(answer(200, "<html>502 Bad Gateway</html>"))

      expect(proxy.get_json("/_profiler/api/profiles")).to eq("raw" => "<html>502 Bad Gateway</html>")
    end

    it "gives an empty hash for an empty body and for a 204" do
      stub_start(answer(200, ""))
      expect(proxy.get_json("/_profiler/api/profiles")).to eq({})

      stub_start(answer(204, nil))
      expect(proxy.delete_json("/_profiler/api/profiles/abc")).to eq({})
    end

    it "reports a redirect rather than following it" do
      stub_start(answer(302, ""))

      expect { proxy.get_json("/_profiler/api/profiles") }
        .to raise_error(Profiler::Error, /answered 302 \(redirect not followed\)/)
    end

    it "finds no profile in a malformed answer" do
      stub_start(answer(200, "not json"))

      expect(proxy.load(SecureRandom.hex(16))).to be_nil
    end

    it "lists nothing from an answer without profiles" do
      allow(proxy).to receive(:get_json).and_return("raw" => "oops")

      expect(proxy.list).to eq([])
    end

    it "unwraps a profile sent under the profile key" do
      allow(proxy).to receive(:get_json).and_return(
        "profile" => { "token" => "0a1b2c3d4e5f60718293a4b5c6d7e8f9", "profile_type" => "http", "path" => "/x",
                       "method" => "GET", "status" => 200, "duration" => 1.0, "started_at" => Time.now.iso8601 }
      )

      expect(proxy.load("0a1b2c3d4e5f60718293a4b5c6d7e8f9").path).to eq("/x")
    end

    it "does not ask the slave for a token or a parent token that is not valid" do
      allow(proxy).to receive(:get_json)

      expect(proxy.load("../../etc")).to be_nil
      expect(proxy.find_by_parent("nope")).to eq([])
      expect(proxy).not_to have_received(:get_json)
    end
  end

  describe "#clear" do
    it "deletes all profiles, or those of one type, on the slave" do
      allow(proxy).to receive(:delete_json).and_return({})

      proxy.clear
      proxy.clear(type: "job")

      expect(proxy).to have_received(:delete_json).with("/_profiler/api/profiles/clear")
      expect(proxy).to have_received(:delete_json).with("/_profiler/api/profiles/clear?type=job")
    end
  end

  describe "the path of a request" do
    it "is refused when it leaves the slave's API, before anything is sent" do
      allow(Net::HTTP).to receive(:start)

      expect { proxy.get_json("/other/path") }.to raise_error(Profiler::Error, /Refusing to send a request/)
      expect { proxy.post_json("/_profiler/api/../admin") }.to raise_error(Profiler::Error, /Refusing/)
      expect { proxy.patch_json("/_profiler/api//x") }.to raise_error(Profiler::Error, /Refusing/)
      expect { proxy.delete_json("/_profiler/api/%2e%2e/x") }.to raise_error(Profiler::Error, /Refusing/)
      expect(Net::HTTP).not_to have_received(:start)
    end
  end
end
