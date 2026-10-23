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

  describe "saving, loading and deleting" do
    let(:blobs) { File.join(@dir, "blobs") }

    def with_body(profile, body)
      profile.add_collector_data("http", { "requests" => [{ "url" => "https://api.test/", "response_body" => body }] })
      profile
    end

    it "round-trips a profile" do
      profile = save(profile_started(Time.now))

      loaded = store.load(profile.token)

      expect(loaded.token).to eq(profile.token)
      expect(loaded.path).to eq("/")
      expect(loaded.status).to eq(200)
    end

    it "keeps the collector data that has no HTTP requests as it is" do
      profile = profile_started(Time.now)
      profile.add_collector_data("http", { "other" => 1 })
      profile.add_collector_data("db", { "queries" => [] })
      save(profile)

      data = store.load(profile.token).collectors_data
      expect(data["http"]).to eq("other" => 1)
      expect(data["db"]).to eq("queries" => [])
    end

    it "answers nil for an unknown token and for one that is not a token" do
      expect(store.load("f" * 32)).to be_nil
      expect(store.load("../etc/passwd")).to be_nil
    end

    it "answers nil, and logs, when the database fails while loading" do
      allow(Profiler).to receive(:log_error)
      allow(db).to receive(:get_first_row).and_raise(SQLite3::Exception, "disk I/O error")

      expect(store.load("f" * 32)).to be_nil
      expect(Profiler).to have_received(:log_error).with(/could not load profile/, an_instance_of(SQLite3::Exception))
    end

    it "answers nil, and logs, for a row that cannot be turned into a profile" do
      profile = save(profile_started(Time.now))
      allow(Profiler).to receive(:log_error)
      allow(Profiler::Models::Profile).to receive(:new).and_raise(ArgumentError, "bad row")

      expect(store.load(profile.token)).to be_nil
      expect(Profiler).to have_received(:log_error).with(/could not deserialize profile #{profile.token}/, anything)
    end

    it "falls back to empty values for a column holding broken JSON" do
      profile = save(profile_started(Time.now))
      db.execute("UPDATE profiler_profiles SET response_headers = ?, params = ?, headers = ? WHERE token = ?",
                 ["{oops", "", nil, profile.token])

      loaded = store.load(profile.token)

      expect(loaded.response_headers).to eq({})
      expect(loaded.params).to eq({})
      expect(loaded.headers).to eq({})
    end

    it "answers nil, and logs, for a row whose start time is not a time" do
      profile = save(profile_started(Time.now))
      db.execute("UPDATE profiler_profiles SET started_at = ? WHERE token = ?", ["not a time", profile.token])
      allow(Profiler).to receive(:log_error)

      expect(store.load(profile.token)).to be_nil
      expect(Profiler).to have_received(:log_error).with(/could not deserialize profile #{profile.token}/, anything)
    end

    describe "#delete" do
      it "removes the row and the blobs of the profile, and leaves the others" do
        gone = save(with_body(profile_started(Time.now), "GONE"))
        kept = save(with_body(profile_started(Time.now), "KEPT"))

        store.delete(gone.token)

        expect(store.load(gone.token)).to be_nil
        expect(File.exist?(File.join(blobs, gone.token))).to be(false)
        expect(File.exist?(File.join(blobs, kept.token))).to be(true)
        expect(store.load(kept.token)).not_to be_nil
      end

      it "ignores a token that is not valid" do
        expect { store.delete("../blobs") }.not_to raise_error
      end
    end

    describe "#clear" do
      it "removes every row and every blob" do
        tokens = 2.times.map { save(with_body(profile_started(Time.now), "BODY")).token }

        store.clear

        expect(tokens.map { |t| store.load(t) }).to all(be_nil)
        expect(tokens.map { |t| File.exist?(File.join(blobs, t)) }).to all(be(false))
      end

      it "removes the profiles of one type, and their blobs only" do
        request = save(with_body(profile_started(Time.now), "REQ"))
        job = profile_started(Time.now)
        job.profile_type = "job"
        with_body(job, "JOB")
        save(job)

        store.clear(type: "job")

        expect(store.load(job.token)).to be_nil
        expect(File.exist?(File.join(blobs, job.token))).to be(false)
        expect(store.load(request.token)).not_to be_nil
        expect(File.exist?(File.join(blobs, request.token))).to be(true)
      end
    end
  end

  describe "#find_by_trace" do
    let(:trace_id) { SecureRandom.hex(16) }

    it "returns the profiles of the trace only, oldest first" do
      later = build_profile(trace_id: trace_id, span_id: "b" * 16, started_at: Time.now)
      earlier = build_profile(trace_id: trace_id, span_id: "a" * 16, parent_span_id: "c" * 16, started_at: Time.now - 10)
      other = build_profile(trace_id: SecureRandom.hex(16))
      [later, earlier, other].each { |p| store.save(p.token, p) }

      results = store.find_by_trace(trace_id)

      expect(results.map(&:token)).to eq([earlier.token, later.token])
      expect(results.first.span_id).to eq("a" * 16)
      expect(results.first.parent_span_id).to eq("c" * 16)
    end

    it "forgets a profile that was deleted" do
      kept = build_profile(trace_id: trace_id)
      gone = build_profile(trace_id: trace_id)
      [kept, gone].each { |p| store.save(p.token, p) }
      store.delete(gone.token)

      expect(store.find_by_trace(trace_id).map(&:token)).to eq([kept.token])
    end

    it "returns an empty array for an unknown or invalid trace id" do
      expect(store.find_by_trace(SecureRandom.hex(16))).to be_empty
      expect(store.find_by_trace("none")).to be_empty
    end
  end

  describe "lists" do
    it "pages newest first and finds the children of a profile" do
      parent = save(profile_started(Time.now - 30))
      child = profile_started(Time.now - 20)
      child.parent_token = parent.token
      save(child)
      newest = save(profile_started(Time.now - 10))

      expect(store.list(limit: 10).map(&:token)).to eq([newest.token, child.token, parent.token])
      expect(store.list(limit: 1, offset: 1).map(&:token)).to eq([child.token])
      expect(store.find_by_parent(parent.token).map(&:token)).to eq([child.token])
    end

    it "gives summaries, and falls back to the whole row for one written without its summary" do
      profile = save(profile_started(Time.now))
      db.execute("UPDATE profiler_profiles SET summary = NULL WHERE token = ?", [profile.token])

      listed = store.list(limit: 5, summary: true)

      expect(listed.map(&:token)).to eq([profile.token])
    end

    it "skips, and logs, a summary that is not valid JSON" do
      profile = save(profile_started(Time.now))
      db.execute("UPDATE profiler_profiles SET summary = ? WHERE token = ?", ["{broken", profile.token])
      allow(Profiler).to receive(:log_error)

      expect(store.list(limit: 5, summary: true)).to be_empty
      expect(Profiler).to have_received(:log_error).with(/could not read the summary of #{profile.token}/, anything)
    end
  end

  describe "fork handling" do
    before { skip "on Ruby < 3.1" unless Process.respond_to?(:_fork) }

    around do |example|
      original_storage = Profiler.instance_variable_get(:@storage)
      original_backend = Profiler.configuration.storage
      original_options = Profiler.configuration.storage_options
      example.run
    ensure
      Profiler.configure do |c|
        c.storage = original_backend
        c.storage_options = original_options
      end
      Profiler.instance_variable_set(:@storage, original_storage)
    end

    it "rebuilds Profiler.storage with a fresh connection in the child process after fork" do
      fork_db_path = File.join(@dir, "fork_test.db")
      fork_blob_path = File.join(@dir, "fork_test_blobs")
      Profiler.configure do |c|
        c.storage = :sqlite
        c.storage_options = { database: fork_db_path, blob_path: fork_blob_path, max_profiles: nil }
      end
      Profiler.instance_variable_set(:@storage, nil)

      parent_store = Profiler.storage
      profile = profile_started(Time.now)
      parent_store.save(profile.token, profile)
      token = profile.token

      fork do
        # The inherited handle must have been discarded (sqlite3 >= 2.0) before Profiler.storage
        # is even called again: otherwise this only proves a fresh connection was built, not that
        # the old one was neutralized, which a worker reusing it would still hit "closed database"
        # or worse through.
        inherited_db = parent_store.instance_variable_get(:@db)
        discarded = inherited_db.respond_to?(:closed?) ? inherited_db.closed? : true

        # Profiler.storage must have been cleared by the fork hook: this rebuilds it with a
        # fresh connection, distinct from the parent's, rather than reusing the inherited one.
        child_store = Profiler.storage
        reloaded = child_store.load(token)

        if discarded && !child_store.equal?(parent_store) && reloaded && reloaded.token == token
          exit! 0
        else
          exit! 1
        end
      rescue
        exit! 2
      end

      Process.wait
      child_exit_status = $?.exitstatus

      expect(child_exit_status).to eq(0)
    end
  end
end
