# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "sqlite3"
require "profiler/storage/sqlite_store"

RSpec.describe Profiler::Storage::SqliteStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:store) { build_store }

  def build_store
    described_class.new(database: File.join(@dir, "profiler.db"), blob_path: File.join(@dir, "blobs"),
                        max_profiles: nil)
  end

  def db
    store.instance_variable_get(:@db)
  end

  def profile_started(started_at)
    profile = Profiler::Models::Profile.new
    profile.path = "/"
    profile.method = "GET"
    profile.status = 200
    profile.duration = 1.0
    profile.started_at = started_at
    profile.finished_at = started_at + 1
    profile
  end

  def save(profile)
    store.save(profile.token, profile)
    profile
  end

  # The process time zone, as a profile records its start in it.
  def in_time_zone(zone)
    previous = ENV["TZ"]
    ENV["TZ"] = zone
    yield
  ensure
    ENV["TZ"] = previous
  end

  describe "the start times" do
    %w[UTC America/New_York Asia/Tokyo Europe/Paris].each do |zone|
      context "in #{zone}" do
        it "removes the profiles older than older_than, and those only" do
          in_time_zone(zone) do
            recent = save(profile_started(Time.now - 30 * 60))
            old = save(profile_started(Time.now - 3 * 60 * 60))

            store.cleanup(older_than: 60 * 60)

            expect(store.load(recent.token)).not_to be_nil
            expect(store.load(old.token)).to be_nil
          end
        end
      end
    end

    it "lists by start, newest first, across a clock change" do
      # New York falls back at 2:00 EDT on 2026-11-01: 01:30 EDT comes before 01:10 EST, which
      # reads earlier as local text.
      earlier = save(profile_started(Time.new(2026, 11, 1, 1, 30, 0, "-04:00")))
      later = save(profile_started(Time.new(2026, 11, 1, 1, 10, 0, "-05:00")))

      expect(store.list(limit: 10).map(&:token)).to eq([later.token, earlier.token])
      db.execute("UPDATE profiler_profiles SET parent_token = ?", ["f" * 32])
      expect(store.find_by_parent("f" * 32).map(&:token)).to eq([earlier.token, later.token])
    end

    it "stores them in UTC and reads them back in local time, the same instants" do
      started_at = Time.at(Time.now.to_i).getlocal("+09:00")
      profile = save(profile_started(started_at))

      row = db.get_first_row("SELECT started_at, finished_at FROM profiler_profiles")
      expect(row["started_at"]).to eq(started_at.utc.iso8601)
      expect(row["finished_at"]).to eq((started_at + 1).utc.iso8601)

      loaded = store.load(profile.token)
      expect(loaded.started_at).to eq(started_at)
      expect(loaded.started_at.utc_offset).to eq(Time.now.utc_offset)
      expect(store.list(limit: 1, summary: true).first.started_at).to eq(started_at)
    end
  end

  describe "a database written before the times were stored in UTC" do
    let(:path) { File.join(@dir, "profiler.db") }

    def legacy_row(token, started_at)
      legacy = SQLite3::Database.new(path)
      legacy.execute(<<~SQL, [token, started_at, started_at])
        INSERT INTO profiler_profiles (token, path, method, status, duration, started_at, finished_at,
                                       tabs, params, headers, response_headers, collectors_meta)
        VALUES (?, '/', 'GET', 200, 1.0, ?, ?, '[]', '{}', '{}', '{}', '{}')
      SQL
      legacy.execute("PRAGMA user_version = 0")
      legacy.close
    end

    it "has its rows rewritten in UTC once, on open" do
      build_store.instance_variable_get(:@db).close
      now = Time.at(Time.now.to_i)
      old_token = "a" * 32
      recent_token = "b" * 32
      legacy_row(old_token, (now - 3 * 3600).getlocal("-04:00").iso8601)
      legacy_row(recent_token, (now - 1800).getlocal("-04:00").iso8601)
      legacy_row("c" * 32, "not a time")

      reopened = build_store
      rows = reopened.instance_variable_get(:@db).execute("SELECT token, started_at FROM profiler_profiles ORDER BY token")
      expect(rows.map { |r| r["started_at"] }).to eq(
        [(now - 3 * 3600).utc.iso8601, (now - 1800).utc.iso8601, "not a time"]
      )
      expect(reopened.instance_variable_get(:@db).get_first_value("PRAGMA user_version")).to eq(1)

      reopened.cleanup(older_than: 3600)
      expect(reopened.load(old_token)).to be_nil
      expect(reopened.load(recent_token)).not_to be_nil
    end
  end

  describe "the response body blobs" do
    let(:blobs) { File.join(@dir, "blobs") }

    def with_body(profile, body)
      profile.add_collector_data("http", { "requests" => [{ "url" => "https://api.test/", "response_body" => body }] })
      profile
    end

    def body_of(token)
      store.load(token).collectors_data["http"]["requests"].first["response_body"]
    end

    it "are dropped when the profile is saved again without a body" do
      profile = save(with_body(profile_started(Time.now), "SECRET-OLD"))
      expect(body_of(profile.token)).to eq("SECRET-OLD")

      save(with_body(profile, nil))

      expect(body_of(profile.token)).to be_nil
      expect(File.exist?(File.join(blobs, profile.token))).to be(false)
    end

    it "are dropped when the profile is saved again without its HTTP requests" do
      profile = save(with_body(profile_started(Time.now), "SECRET-OLD"))
      profile.collectors_data.delete("http")
      save(profile)

      expect(File.exist?(File.join(blobs, profile.token))).to be(false)
    end

    it "are replaced when the profile is saved again with another body" do
      profile = save(with_body(profile_started(Time.now), "OLD"))
      save(with_body(profile, "NEW"))

      expect(body_of(profile.token)).to eq("NEW")
    end

    describe "left without a row" do
      def orphan(token, age:)
        dir = File.join(blobs, token)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "http_response_bodies.json"), "[]")
        File.utime(Time.now - age, Time.now - age, dir)
        dir
      end

      it "are removed by cleanup, the recent ones and those of a row left alone" do
        kept = save(with_body(profile_started(Time.now), "KEPT"))
        File.utime(Time.now - 3600, Time.now - 3600, File.join(blobs, kept.token))
        old_orphan = orphan("a" * 32, age: 3600)
        fresh_orphan = orphan("b" * 32, age: 0)
        unrelated = File.join(blobs, "not-a-token")
        FileUtils.mkdir_p(unrelated)

        store.cleanup(older_than: 24 * 3600)

        expect(File.exist?(old_orphan)).to be(false)
        expect(File.exist?(fresh_orphan)).to be(true)
        expect(File.exist?(unrelated)).to be(true)
        expect(body_of(kept.token)).to eq("KEPT")
      end

      it "are removed by cleanup(older_than: 0)" do
        old_orphan = orphan("a" * 32, age: 3600)

        store.cleanup(older_than: 0)

        expect(File.exist?(old_orphan)).to be(false)
      end

      it "are removed when the oldest profiles are evicted" do
        capped = described_class.new(database: File.join(@dir, "profiler.db"), blob_path: blobs, max_profiles: 2)
        old_orphan = orphan("a" * 32, age: 3600)
        3.times { p = profile_started(Time.now); capped.save(p.token, p) }

        expect(File.exist?(old_orphan)).to be(false)
      end
    end
  end
end
