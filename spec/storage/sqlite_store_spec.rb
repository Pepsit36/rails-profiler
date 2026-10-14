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
end
