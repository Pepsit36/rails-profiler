# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "base_store"
require_relative "blob_store"
require_relative "private_files"
require_relative "summary"
require_relative "token"
require_relative "../models/profile"

module Profiler
  module Storage
    class SqliteStore < BaseStore
      # Past max_profiles, the oldest profiles are evicted down to this share of it.
      LOW_WATER = 0.8

      def initialize(options = {})
        require "sqlite3"

        @max_profiles = options.key?(:max_profiles) ? options[:max_profiles] : Profiler.configuration.max_profiles

        db_path = (options[:database] || default_db_path).to_s
        blob_path = options[:blob_path] || PrivateFiles.tmp_dir("blobs")

        prepare_database_file(db_path, default: options[:database].nil?)

        @db = SQLite3::Database.new(db_path)
        @db.results_as_hash = true
        @db.busy_timeout = 5000
        @db.execute("PRAGMA journal_mode=WAL")
        @db.execute("PRAGMA synchronous=NORMAL")

        @blob_store = BlobStore.new(blob_path.to_s)

        migrate!
      end

      def do_save(token, profile)
        data = profile.to_h

        collectors_meta = {}
        (data[:collectors_data] || {}).each do |collector_name, collector_data|
          next unless collector_data.is_a?(Hash)

          if collector_name.to_s == "http"
            requests = collector_data["requests"]
            if requests
              stripped = save_http_response_bodies(token, requests)
              collectors_meta[collector_name] = collector_data.merge("requests" => stripped)
            else
              collectors_meta[collector_name] = collector_data
            end
          else
            collectors_meta[collector_name] = collector_data
          end
        end

        @db.execute(
          <<~SQL,
            INSERT OR REPLACE INTO profiler_profiles (
              token, profile_type, gem_version, path, method, status, duration, memory,
              started_at, finished_at, parent_token, is_ajax,
              tabs, params, headers, response_headers, collectors_meta, summary
            ) VALUES (
              :token, :profile_type, :gem_version, :path, :method, :status, :duration, :memory,
              :started_at, :finished_at, :parent_token, :is_ajax,
              :tabs, :params, :headers, :response_headers, :collectors_meta, :summary
            )
          SQL
          token:            token,
          profile_type:     data[:profile_type] || "http",
          gem_version:      data[:gem_version],
          path:             data[:path],
          method:           data[:method],
          status:           data[:status],
          duration:         data[:duration],
          memory:           data[:memory],
          started_at:       data[:started_at],
          finished_at:      data[:finished_at],
          parent_token:     data[:parent_token],
          is_ajax:          data[:is_ajax] ? 1 : 0,
          tabs:             JSON.generate(data[:tabs] || []),
          params:           JSON.generate(data[:params] || {}),
          headers:          JSON.generate(data[:headers] || {}),
          response_headers: JSON.generate(data[:response_headers] || {}),
          collectors_meta:  JSON.generate(collectors_meta),
          summary:          JSON.generate(Summary.build(data))
        )
        evict_oldest

        token
      end

      def load(token)
        return nil unless Token.valid?(token)

        row = @db.get_first_row(
          "SELECT * FROM profiler_profiles WHERE token = :token", token: token
        )
        return nil unless row

        row_to_profile(row)
      rescue => e
        warn "SqliteStore: failed to load profile #{token}: #{e.message}"
        nil
      end

      # Newest first. summary: true reads the summary column only, for the rows that have it.
      def list(limit: 50, offset: 0, type: nil, summary: false)
        where = type ? "WHERE profile_type = :type" : ""
        rows = @db.execute(
          "SELECT * FROM profiler_profiles #{where} ORDER BY started_at DESC, rowid DESC LIMIT :limit OFFSET :offset",
          { limit: limit, offset: offset }.merge(type ? { type: type.to_s } : {})
        )
        return rows.filter_map { |row| row_to_profile(row, load_blobs: false) } unless summary

        rows.filter_map { |row| row_to_summary(row) }
      end

      def find_by_parent(parent_token)
        return [] unless Token.valid?(parent_token)

        rows = @db.execute(
          "SELECT * FROM profiler_profiles WHERE parent_token = :parent_token ORDER BY started_at ASC",
          parent_token: parent_token
        )
        rows.map { |row| row_to_profile(row) }.compact
      end

      def delete(token)
        return unless Token.valid?(token)

        @db.execute("DELETE FROM profiler_profiles WHERE token = :token", token: token)
        @blob_store.delete(token)
      end

      def clear(type: nil)
        if type.nil?
          tokens = @db.execute("SELECT token FROM profiler_profiles").map { |r| r["token"] }
          @db.execute("DELETE FROM profiler_profiles")
        else
          tokens = @db.execute(
            "SELECT token FROM profiler_profiles WHERE profile_type = :type", type: type.to_s
          ).map { |r| r["token"] }
          @db.execute("DELETE FROM profiler_profiles WHERE profile_type = :type", type: type.to_s)
        end
        tokens.each { |token| @blob_store.delete(token) }
      end

      def cleanup(older_than: 24 * 60 * 60)
        cutoff = (Time.now - older_than).utc.iso8601
        tokens = @db.execute(
          "SELECT token FROM profiler_profiles WHERE started_at < :cutoff", cutoff: cutoff
        ).map { |r| r["token"] }
        @db.execute("DELETE FROM profiler_profiles WHERE started_at < :cutoff", cutoff: cutoff)
        tokens.each { |token| @blob_store.delete(token) }
      end

      private

      # One query on the started_at index tells whether the table holds more than max_profiles.
      def evict_oldest
        return unless @max_profiles
        return unless @db.get_first_value(
          "SELECT 1 FROM profiler_profiles ORDER BY started_at DESC, rowid DESC LIMIT 1 OFFSET :max", max: @max_profiles
        )

        keep = [(@max_profiles * LOW_WATER).floor, 1].max
        tokens = @db.execute(
          "SELECT token FROM profiler_profiles ORDER BY started_at DESC, rowid DESC LIMIT -1 OFFSET :keep", keep: keep
        ).map { |r| r["token"] }
        tokens.each_slice(500) do |slice|
          @db.execute("DELETE FROM profiler_profiles WHERE token IN (#{(["?"] * slice.size).join(",")})", slice)
        end
        tokens.each { |token| @blob_store.delete(token) }
      end

      # A row written before the summary column falls back to the whole row, summarized.
      def row_to_summary(row)
        if row["summary"].nil? || row["summary"].empty?
          profile = row_to_profile(row, load_blobs: false)
          return profile && Summary.to_profile(Summary.build(profile))
        end

        Summary.to_profile(JSON.parse(row["summary"]))
      rescue JSON::ParserError => e
        warn "SqliteStore: failed to read the summary of #{row["token"]}: #{e.message}"
        nil
      end

      def save_http_response_bodies(token, requests)
        bodies = requests.map do |req|
          { "response_body" => req["response_body"], "response_body_encoding" => req["response_body_encoding"] }
        end

        return requests unless bodies.any? { |b| !b["response_body"].nil? }

        @blob_store.write(token, "http_response_bodies", bodies)

        requests.map do |req|
          req.reject { |k, _| %w[response_body response_body_encoding].include?(k) }
        end
      end

      def load_http_response_bodies(token, requests)
        return requests if requests.nil? || requests.empty?

        bodies = @blob_store.read(token, "http_response_bodies")
        return requests if bodies.nil? || bodies.empty?

        requests.each_with_index.map do |req, i|
          entry = bodies[i]
          next req unless entry

          body     = entry["response_body"]
          encoding = entry["response_body_encoding"]
          merged   = req.dup
          merged["response_body"]          = body     unless body.nil?
          merged["response_body_encoding"] = encoding unless encoding.nil?
          merged
        end
      end

      def migrate!
        @db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS profiler_profiles (
            token              TEXT PRIMARY KEY,
            profile_type       TEXT NOT NULL DEFAULT 'http',
            gem_version        TEXT,
            path               TEXT,
            method             TEXT,
            status             INTEGER,
            duration           REAL,
            memory             INTEGER,
            started_at         TEXT,
            finished_at        TEXT,
            parent_token       TEXT,
            is_ajax            INTEGER NOT NULL DEFAULT 0,
            tabs               TEXT,
            params             TEXT,
            headers            TEXT,
            response_headers   TEXT,
            collectors_meta    TEXT,
            created_at         TEXT NOT NULL DEFAULT (datetime('now', 'utc'))
          );

          CREATE INDEX IF NOT EXISTS idx_profiler_started_at
            ON profiler_profiles(started_at DESC);

          CREATE INDEX IF NOT EXISTS idx_profiler_parent_token
            ON profiler_profiles(parent_token);

          CREATE INDEX IF NOT EXISTS idx_profiler_profile_type
            ON profiler_profiles(profile_type);
        SQL

        %w[gem_version summary].each do |column|
          @db.execute("ALTER TABLE profiler_profiles ADD COLUMN #{column} TEXT")
        rescue SQLite3::Exception
          # column already exists
        end
      end

      def row_to_profile(row, load_blobs: true)
        collectors_meta = parse_json(row["collectors_meta"], {})

        collectors_data = collectors_meta.transform_keys(&:to_s).transform_values do |v|
          Models::Profile.deep_stringify_keys(v)
        end

        if load_blobs && collectors_data.key?("http")
          requests = collectors_data["http"]["requests"]
          if requests
            collectors_data["http"]["requests"] = load_http_response_bodies(row["token"], requests)
          end
        end

        req_collector = collectors_data["request"] || {}

        Models::Profile.from_hash(
          token:                  row["token"],
          profile_type:           row["profile_type"],
          gem_version:            row["gem_version"],
          path:                   row["path"],
          method:                 row["method"],
          status:                 row["status"],
          duration:               row["duration"],
          memory:                 row["memory"],
          started_at:             row["started_at"],
          finished_at:            row["finished_at"],
          parent_token:           row["parent_token"],
          is_ajax:                row["is_ajax"] == 1,
          tabs:                   parse_json(row["tabs"], []),
          params:                 parse_json(row["params"], {}),
          headers:                parse_json(row["headers"], {}),
          response_headers:       parse_json(row["response_headers"], {}),
          request_body:           req_collector["request_body"],
          request_body_encoding:  req_collector["request_body_encoding"],
          response_body:          req_collector["response_body"],
          response_body_encoding: req_collector["response_body_encoding"],
          collectors_data:        collectors_data
        )
      rescue => e
        warn "SqliteStore: failed to deserialize profile #{row["token"]}: #{e.message}"
        nil
      end

      def parse_json(value, default)
        return default if value.nil? || value.empty?

        JSON.parse(value)
      rescue JSON::ParserError
        default
      end

      # SQLite gives the -wal and -shm files the mode of the database file: create it 0600 before
      # SQLite does, and bring an older one, and its companions, back to 0600. An in-memory or URI
      # database is left to SQLite.
      def prepare_database_file(db_path, default:)
        return if db_path == ":memory:" || db_path.start_with?("file:")

        default ? PrivateFiles.tmp_dir : PrivateFiles.mkdir(File.dirname(db_path))
        # A link in place of one of them is refused: SQLite would follow it.
        %w[-wal -shm].each { |suffix| PrivateFiles.refuse_link("#{db_path}#{suffix}") }
        PrivateFiles.touch(db_path)
        %w[-wal -shm].each { |suffix| PrivateFiles.restrict("#{db_path}#{suffix}") }
      end

      def default_db_path
        Profiler.configuration.tmp_path.join("profiler.db")
      end

    end
  end
end
