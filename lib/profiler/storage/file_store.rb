# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "base_store"
require_relative "private_files"
require_relative "summary"
require_relative "token"
require_relative "../models/profile"

module Profiler
  module Storage
    # File-based profile storage backend. Persists each profile as a JSON file named after its
    # token, under tmp_path/profiles by default or the directory given as options[:path]. Only the
    # files named after a token are taken for profiles, so a path shared with other files (tmp_path
    # itself, where the env overrides live) is safe.
    #
    # An index next to the profiles (INDEX_FILE) holds one line per save or delete: the token, the
    # size of the file, the type, the parent and the summary the lists show. Every process keeps it
    # in memory and reads only the lines appended since its last read, its own and those of the
    # other processes writing to the directory (Puma workers, Sidekiq), so a save no longer lists
    # or stats the directory. A save writes its file and its line under a shared flock; the
    # compaction, which evicts the first saved profiles past max_profiles or max_size,
    # resynchronizes the index with the directory (profiles written without it, files removed by
    # hand, temporary files left by a killed writer) and rewrites it, holds the exclusive one: a
    # save past a cap waits for it, a compaction of dead lines only gives up when another process
    # holds it. A missing or damaged index is rebuilt from the files. flock has to work across
    # the processes sharing the directory: one host, not NFS between hosts (see the README).
    class FileStore < BaseStore
      INDEX_FILE = ".profiles-index.jsonl"
      LOCK_FILE = ".profiles-index.lock"
      INDEX_VERSION = 1
      PROFILE_FILE = /\A(\h{32})\.json\z/
      # The temporary files PrivateFiles.write makes for this store: a profile or the index, then
      # the pid and a random part. Any other file of a shared directory is left alone.
      TEMPORARY_FILE = /\A\.(?:\h{32}\.json|#{Regexp.escape(INDEX_FILE)})\.\d+\.\h{8}\.tmp\z/
      # A temporary file older than this is one a killed writer left behind.
      STALE_TEMPORARY_AGE = 60
      # Past a cap, the oldest profiles are evicted down to this share of it.
      LOW_WATER = 0.8

      Entry = Struct.new(:token, :at, :type, :parent, :bytes, :summary, :sequence)

      def initialize(options = {})
        super()
        @max_size = options[:max_size] || (100 * 1024 * 1024) # 100 MB
        @max_profiles = options.key?(:max_profiles) ? options[:max_profiles] : Profiler.configuration.max_profiles
        if options[:path]
          @path = options[:path].to_s
          PrivateFiles.mkdir(@path)
        else
          @path = PrivateFiles.tmp_dir("profiles").to_s
        end
        @index_path = File.join(@path, INDEX_FILE)
        @lock_path = File.join(@path, LOCK_FILE)
        # Left with a wider mode by an earlier run: back to 0600 (a link is refused).
        PrivateFiles.restrict(@lock_path)
        PrivateFiles.restrict(@index_path)
        @mutex = Mutex.new
        forget_index
      end

      def do_save(token, profile)
        data = profile.to_h
        json = data.to_json
        line = JSON.generate(put_record(token, data, json.bytesize, started_at: profile.started_at))
        @mutex.synchronize do
          refresh if @generation.nil? # the index exists, with its header, before the first line
          # The file and its line under one shared lock: a compaction sees both or neither, and
          # cannot evict the file before its line is written.
          with_lock(File::LOCK_SH) do
            PrivateFiles.write(profile_file_path(token), json)
            begin
              PrivateFiles.append(@index_path, "#{line}\n")
            rescue StandardError
              # A file the index never learns of would be listed by no one and counted nowhere.
              FileUtils.rm_f(profile_file_path(token))
              raise
            end
          end
          refresh
          if over_cap?
            compact(keep: token)
          elsif compaction_due?
            # Dead lines only: another process compacting meanwhile does it for this one.
            compact(keep: token, wait: false)
          end
        end
        token
      end

      def load(token)
        return nil unless Token.valid?(token)

        file_path = profile_file_path(token)
        return nil unless File.exist?(file_path)

        json_data = File.read(file_path)
        Models::Profile.from_json(json_data)
      rescue StandardError => e
        warn "Failed to load profile #{token}: #{e.message}"
        nil
      end

      # Newest first. summary: true reads no profile file, only the index.
      def list(limit: 50, offset: 0, type: nil, summary: false)
        page = @mutex.synchronize do
          refresh
          entries = sorted_entries
          entries = entries.select { |entry| entry.type == type.to_s } if type
          entries.drop(offset).first(limit)
        end
        if summary
          page.filter_map { |entry| Summary.to_profile(entry.summary) if entry.summary }
        else
          page.filter_map { |entry| load(entry.token) }
        end
      end

      # By the modification time of the files, as before the index: an explicit task, which may
      # stat every profile.
      def cleanup(older_than: 24 * 60 * 60)
        cutoff = Time.now - older_than
        @mutex.synchronize do
          compact { |entries| entries.values.select { |entry| modified_before?(entry.token, cutoff) } }
        end
      end

      def find_by_parent(parent_token)
        return [] unless Token.valid?(parent_token)

        children = @mutex.synchronize do
          refresh
          (@children[parent_token] || {}).keys.filter_map { |token| @entries[token] }
        end
        children.filter_map { |entry| load(entry.token) }.sort_by(&:started_at)
      end

      def delete(token)
        return unless Token.valid?(token)

        @mutex.synchronize do
          refresh if @generation.nil?
          with_lock(File::LOCK_SH) do
            FileUtils.rm_f(profile_file_path(token))
            PrivateFiles.append(@index_path, "#{JSON.generate("op" => "del", "token" => token)}\n")
          end
          refresh
        end
      end

      def clear(type: nil)
        @mutex.synchronize do
          compact { |entries| entries.values.select { |entry| type.nil? || entry.type == type.to_s } }
        end
      end

      private

      def profile_file_path(token)
        File.join(@path, "#{token}.json")
      end

      def modified_before?(token, cutoff)
        File.mtime(profile_file_path(token)) < cutoff
      rescue Errno::ENOENT
        true
      end

      # started_at: the profile's own, more precise than the second of its JSON form.
      def put_record(token, data, bytes, started_at: nil)
        started_at = started_at&.to_f || (data[:started_at] ? Time.parse(data[:started_at]).to_f : Time.now.to_f)
        { "op" => "put", "token" => token, "at" => started_at, "type" => (data[:profile_type] || "http").to_s,
          "parent" => data[:parent_token], "bytes" => bytes, "summary" => Summary.build(data) }
      end

      def forget_index
        @entries = {}
        @sequence = 0
        @children = {}
        @bytes = 0
        @records = 0
        @offset = 0
        @generation = nil
        @damaged = false
        @sorted = nil
      end

      # Brings the in-memory index up to date with the file: the appended lines only, or the whole
      # file when another process rewrote it. A missing or damaged index is rebuilt.
      def refresh
        PrivateFiles.open_for_reading(@index_path) do |file|
          header = parse_line(file.gets)
          if header.nil? || header["profiler_index"] != INDEX_VERSION || !header["generation"].is_a?(String)
            @damaged = true
          elsif header["generation"] != @generation || file.size < @offset
            forget_index
            @generation = header["generation"]
            @offset = file.pos
            read_records(file)
          elsif file.size > @offset
            file.seek(@offset)
            read_records(file)
          end
        end
        compact if @damaged
      rescue Errno::ENOENT
        compact
      end

      # Consumes the complete lines from the file's position; a line still being written by
      # another process is left for the next read.
      def read_records(file)
        data = file.read
        complete = data.rindex("\n")
        return unless complete

        data[0..complete].each_line do |line|
          record = parse_line(line)
          record ? apply(record) : @damaged = true
        end
        @offset += data[0..complete].bytesize
      end

      def parse_line(line)
        return nil if line.nil?

        record = JSON.parse(line)
        record.is_a?(Hash) ? record : nil
      rescue JSON::ParserError
        nil
      end

      # A record whose token is not one the gem issues is skipped: it is never turned into a path.
      def apply(record)
        token = record["token"]
        return unless Token.valid?(token)

        @records += 1
        case record["op"]
        when "put"
          remove_entry(token)
          parent = Token.valid?(record["parent"]) ? record["parent"] : nil
          add_entry(Entry.new(token, record["at"].to_f, record["type"], parent, record["bytes"].to_i,
                              record["summary"].is_a?(Hash) ? record["summary"] : nil))
        when "del"
          remove_entry(token)
        end
      end

      def add_entry(entry)
        entry.sequence = (@sequence += 1)
        @entries[entry.token] = entry
        @bytes += entry.bytes
        (@children[entry.parent] ||= {})[entry.token] = true if entry.parent
        @sorted = nil
      end

      def remove_entry(token)
        entry = @entries.delete(token)
        return unless entry

        @bytes -= entry.bytes
        if entry.parent && (siblings = @children[entry.parent])
          siblings.delete(token)
          @children.delete(entry.parent) if siblings.empty?
        end
        @sorted = nil
      end

      def sorted_entries
        # Two profiles started in the same instant: the one saved last first.
        @sorted ||= @entries.values.sort_by { |entry| [-entry.at, -entry.sequence] }
      end

      def over_cap?
        (@max_profiles && @entries.size > @max_profiles) || @bytes >= @max_size
      end

      # The file holds more dead lines (replaced or deleted profiles) than live ones.
      def compaction_due?
        over_cap? || @records > (2 * @entries.size) + 64
      end

      # Under the exclusive lock: reads the whole index again, resynchronizes it with the
      # directory, takes out the profiles the block returns (if any) and the first saved past the
      # caps, never keep (the profile just saved), rewrites the index, then removes their files:
      # a reader never lists a profile whose file is gone. Another process that compacted
      # meanwhile leaves nothing to do but the rewrite. wait: false gives up when another process
      # holds the lock.
      def compact(keep: nil, wait: true)
        with_lock(wait ? File::LOCK_EX : File::LOCK_EX | File::LOCK_NB) do
          reload_for_compaction
          resynchronize
          doomed = (block_given? ? yield(@entries) : []).map(&:token)
          doomed.each { |token| remove_entry(token) }
          doomed.concat(evict_first_saved(keep)) if over_cap?
          rewrite_index
          doomed.each { |token| FileUtils.rm_f(profile_file_path(token)) }
        end
      end

      # @last_compacted_at is kept only from a sound index: with a damaged one, a profile whose
      # line was lost would pass for a file the last compaction evicted (see #resynchronize).
      def reload_for_compaction
        forget_index
        @last_compacted_at = nil
        PrivateFiles.open_for_reading(@index_path) do |file|
          header = parse_line(file.gets)
          next unless header && header["profiler_index"] == INDEX_VERSION && header["generation"].is_a?(String)

          sound = true
          file.each_line do |line|
            record = parse_line(line)
            record && line.end_with?("\n") ? apply(record) : sound = false
          end
          @last_compacted_at = header["compacted_at"] if sound && header["compacted_at"].is_a?(Numeric)
        end
      rescue Errno::ENOENT
        nil
      end

      # The directory is the truth: entries whose file is gone are dropped, files the index does
      # not know (written by an older version, or with the index lost) are read once and added,
      # temporary files left by a killed writer are removed. A file the index does not know that
      # is older than the last compaction was evicted by it (a save writes its file and its line
      # under the lock, so a file saved before that compaction is in the index): the process that
      # compacted was killed before it removed the file, which is removed now, not listed again.
      def resynchronize
        names = Dir.children(@path)
        on_disk = names.filter_map { |name| name[PROFILE_FILE, 1] }
        (@entries.keys - on_disk).each { |token| remove_entry(token) }
        unknown = (on_disk - @entries.keys).map { |token| [token, modified_at(token)] }
        evicted, unknown = unknown.partition { |_, mtime| @last_compacted_at && mtime < @last_compacted_at }
        evicted.each { |token, _| FileUtils.rm_f(profile_file_path(token)) }
        # Unknown files in the order they were saved, as far as their modification time tells.
        unknown.sort_by(&:last).each { |token, _| add_entry(entry_from_file(token)) }
        names.grep(TEMPORARY_FILE).each { |name| remove_stale_temporary(File.join(@path, name)) }
      end

      # A symbolic link in place of a profile is not followed while the modes are restricted.
      def entry_from_file(token)
        json = PrivateFiles.open_for_reading(profile_file_path(token), &:read)
        record = put_record(token, Models::Profile.from_json(json).to_h, json.bytesize)
        Entry.new(token, record["at"], record["type"], record["parent"], record["bytes"], record["summary"])
      rescue StandardError
        # Unreadable: kept in the count, so that it is evicted in turn; listed by no one.
        stat = File.lstat(profile_file_path(token)) rescue nil
        Entry.new(token, stat ? stat.mtime.to_f : 0.0, nil, nil, stat ? stat.size : 0, nil)
      end

      def modified_at(token)
        File.lstat(profile_file_path(token)).mtime.to_f
      rescue SystemCallError
        0.0
      end

      def remove_stale_temporary(path)
        File.delete(path) if File.lstat(path).mtime < Time.now - STALE_TEMPORARY_AGE
      rescue SystemCallError
        nil
      end

      # In the order they were saved, not started: a job saved when it ends is a new profile. The
      # entries keep the order of the index lines, the order of the saves.
      def evict_first_saved(keep)
        count_target = @max_profiles && [(@max_profiles * LOW_WATER).floor, 1].max
        bytes_target = @bytes >= @max_size ? @max_size * LOW_WATER : nil
        evicted = []
        @entries.values.each do |entry|
          break unless (count_target && @entries.size > count_target) || (bytes_target && @bytes >= bytes_target)
          next if entry.token == keep

          remove_entry(entry.token)
          evicted << entry.token
        end
        evicted
      end

      def rewrite_index
        generation = SecureRandom.hex(8)
        lines = [JSON.generate("profiler_index" => INDEX_VERSION, "generation" => generation,
                               "compacted_at" => Time.now.to_f)]
        @entries.each_value do |entry|
          lines << JSON.generate("op" => "put", "token" => entry.token, "at" => entry.at, "type" => entry.type,
                                 "parent" => entry.parent, "bytes" => entry.bytes, "summary" => entry.summary)
        end
        data = "#{lines.join("\n")}\n"
        PrivateFiles.write(@index_path, data)
        @generation = generation
        @offset = data.bytesize
        @records = @entries.size
        @damaged = false
      end

      # flock on a file of its own, opened for each use: a lock taken through a descriptor shared
      # with a forked process would not exclude it. The mutex excludes the threads of this one.
      def with_lock(mode)
        PrivateFiles.open(@lock_path) do |file|
          next unless file.flock(mode)

          yield
        end
      end
    end
  end
end
