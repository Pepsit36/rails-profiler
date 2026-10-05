# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../support/fake_redis"
require "profiler/storage/file_store"
require "profiler/storage/redis_store"
require "profiler/storage/sqlite_store"

# PERF-02, PERF-03 and PERF-04 for every backend: the count cap, the type filter and the
# pagination done by the store, the list summaries, and find_by_parent reading the children only.
RSpec.describe "Profile stores at scale" do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:base_time) { Time.at(Time.now.to_i - 3600) }

  def profile_at(index, **attrs)
    build_profile(started_at: base_time + index, finished_at: base_time + index + 0.01,
                  path: "/p#{index}", **attrs)
  end

  def count_deserializations
    calls = 0
    allow(Profiler::Models::Profile).to receive(:from_hash).and_wrap_original do |original, *args|
      calls += 1
      original.call(*args)
    end
    yield
    calls
  end

  shared_examples "a store that scales" do
    describe "max_profiles" do
      it "never keeps more than max_profiles, and evicts the oldest" do
        store = build_store(max_profiles: 5)
        tokens = (0...12).map { |i| profile_at(i).tap { |p| store.save(p.token, p) }.token }

        kept = store.list(limit: 100).map(&:token)
        expect(kept.size).to be <= 5
        expect(kept).to include(tokens.last)
        expect(kept).not_to include(tokens.first)
        expect(store.load(tokens.first)).to be_nil
      end
    end

    describe "#list" do
      it "filters by profile type and paginates in the store, newest first" do
        store = build_store(max_profiles: 100)
        jobs = (0...6).map { |i| profile_at(i, profile_type: "job").tap { |p| store.save(p.token, p) } }
        (6...20).each { |i| profile_at(i).tap { |p| store.save(p.token, p) } }

        page = store.list(limit: 4, offset: 1, type: "job")
        expect(page.map(&:token)).to eq(jobs.reverse.drop(1).first(4).map(&:token))
        expect(store.list(limit: 50, offset: 5, type: "job").size).to eq(1)
      end

      it "deserializes only the profiles of the page" do
        store = build_store(max_profiles: 100)
        (0...30).each { |i| profile_at(i).tap { |p| store.save(p.token, p) } }

        calls = count_deserializations { expect(store.list(limit: 3).size).to eq(3) }
        expect(calls).to be <= 3
      end

      it "returns summaries without the bodies, headers and nested collector data" do
        store = build_store(max_profiles: 100)
        profile = profile_at(1, params: { "q" => "x" }, headers: { "Accept" => "text/html" },
                                collectors_data: { "database" => { "total_queries" => 3, "queries" => [{ "sql" => "SELECT 1" }] },
                                                   "job" => { "queue" => "default", "executions" => 1 },
                                                   "exception" => { "exceptions" => [] } })
        profile.response_body = "<html>#{"x" * 1000}</html>"
        store.save(profile.token, profile)

        summary = store.list(limit: 1, summary: true).first
        expect(summary.token).to eq(profile.token)
        expect(summary.path).to eq("/p1")
        expect(summary.started_at.to_i).to eq(profile.started_at.to_i)
        expect(summary.response_body).to be_nil
        expect(summary.params).to be_nil
        expect(summary.headers).to be_nil
        expect(summary.collector_data("database")).to eq("total_queries" => 3)
        expect(summary.collector_data("job")).to eq("queue" => "default", "executions" => 1)
        expect(summary.collectors_data).to have_key("exception")
      end
    end

    describe "the summaries" do
      let(:secret) { "cluster-secret-0123456789abcdefghijkl" }

      before { Profiler.configure { |config| config.cluster_secret = secret } }
      after { Profiler.configure { |config| config.cluster_secret = nil } }

      it "hold a subset of the stored profile, masked values included, and nothing else" do
        store = build_store(max_profiles: 100)
        profile = profile_at(1, params: { "password" => "[FILTERED]" })
        profile.add_collector_data("request", { "authorization" => "[FILTERED]", "note" => "sent #{secret}",
                                                "cookies" => { "session" => "[FILTERED]" } })
        store.save(profile.token, profile)

        full = store.load(profile.token).to_h
        summary = store.list(limit: 1, summary: true).first.to_h

        expect(summary[:collectors_data]["request"]).to eq("authorization" => "[FILTERED]", "note" => full[:collectors_data]["request"]["note"])
        summary[:collectors_data].each do |name, values|
          values.each { |key, value| expect(full[:collectors_data][name][key]).to eq(value) }
        end
        summary.except(:collectors_data).compact.each do |key, value|
          expect(full[key]).to eq(value), "#{key}: #{value.inspect} is not the stored #{full[key].inspect}"
        end
        expect(summary.to_json).not_to include(secret)
      end
    end

    describe "#find_by_parent" do
      it "returns the children, oldest first, without deserializing the other profiles" do
        store = build_store(max_profiles: 100)
        parent = profile_at(0).tap { |p| store.save(p.token, p) }
        (1..30).each { |i| profile_at(i).tap { |p| store.save(p.token, p) } }
        late = profile_at(40, parent_token: parent.token, profile_type: "job").tap { |p| store.save(p.token, p) }
        early = profile_at(35, parent_token: parent.token).tap { |p| store.save(p.token, p) }

        calls = count_deserializations do
          expect(store.find_by_parent(parent.token).map(&:token)).to eq([early.token, late.token])
        end
        expect(calls).to be <= 2
      end

      it "follows a profile saved again under another parent, and forgets a deleted one" do
        store = build_store(max_profiles: 100)
        first_parent = profile_at(0).tap { |p| store.save(p.token, p) }
        second_parent = profile_at(1).tap { |p| store.save(p.token, p) }
        child = profile_at(2, parent_token: first_parent.token).tap { |p| store.save(p.token, p) }
        gone = profile_at(3, parent_token: second_parent.token).tap { |p| store.save(p.token, p) }

        child.parent_token = second_parent.token
        store.save(child.token, child)
        store.delete(gone.token)

        expect(store.find_by_parent(first_parent.token)).to be_empty
        expect(store.find_by_parent(second_parent.token).map(&:token)).to eq([child.token])
      end
    end

    describe "#clear" do
      it "clears one type without touching the others" do
        store = build_store(max_profiles: 100)
        job = profile_at(0, profile_type: "job").tap { |p| store.save(p.token, p) }
        http = profile_at(1).tap { |p| store.save(p.token, p) }

        store.clear(type: "job")

        expect(store.load(job.token)).to be_nil
        expect(store.list(limit: 10).map(&:token)).to eq([http.token])
        expect(store.list(limit: 10, type: "job")).to be_empty
      end
    end
  end

  shared_examples "a store without a count cap when max_profiles is nil" do
    it "keeps every profile" do
      store = build_store(max_profiles: nil)
      (0...12).each { |i| profile_at(i).tap { |p| store.save(p.token, p) } }
      expect(store.list(limit: 100).size).to eq(12)
    end
  end

  describe Profiler::Storage::MemoryStore do
    def build_store(max_profiles:)
      described_class.new(max_profiles: max_profiles)
    end

    it_behaves_like "a store that scales"
  end

  describe Profiler::Storage::FileStore do
    def build_store(max_profiles:, path: File.join(@dir, "profiles"))
      described_class.new(path: path, max_profiles: max_profiles)
    end

    it_behaves_like "a store that scales"
    it_behaves_like "a store without a count cap when max_profiles is nil"

    it "reads no profile file to list summaries" do
      store = build_store(max_profiles: 100)
      (0...5).each { |i| profile_at(i).tap { |p| store.save(p.token, p) } }
      reads = []
      allow(File).to receive(:read).and_wrap_original { |original, *args| reads << args.first.to_s; original.call(*args) }

      expect(store.list(limit: 5, summary: true).size).to eq(5)
      expect(reads.grep(/\h{32}\.json\z/)).to be_empty
    end
  end

  describe Profiler::Storage::SqliteStore do
    def build_store(max_profiles:)
      described_class.new(database: File.join(@dir, "profiler.db"), blob_path: File.join(@dir, "blobs"),
                          max_profiles: max_profiles)
    end

    it_behaves_like "a store that scales"
    it_behaves_like "a store without a count cap when max_profiles is nil"
  end

  describe Profiler::Storage::RedisStore do
    let(:redis) { FakeRedis.new }

    def build_store(max_profiles:)
      described_class.new(redis: redis, key_prefix: "spec", max_profiles: max_profiles)
    end

    it_behaves_like "a store that scales"
    it_behaves_like "a store without a count cap when max_profiles is nil"
  end
end
