# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "storage/private_files"
require_relative "env_key_policy"

module Profiler
  class EnvOverrideStore
    # Raised by the methods a caller asked for (set, delete, reset, reset_all, clear and
    # all_overrides) when the overrides file cannot be read or written. The caller then knows that
    # nothing was changed. apply! and apply_at_boot! still only warn: they run at boot and before
    # the application's jobs, where an override must never make the application fail.
    class Error < Profiler::Error; end

    DELETED_SENTINEL = "__profiler_deleted__"
    RESTORE_SENTINEL = "__profiler_restore__"

    # Why the persisted overrides are left out of ENV, as logged at boot.
    BLOCKED_REASONS = {
      production: "persisted overrides are never applied in production; " \
                  "delete the file if it was deployed by mistake",
      disabled: "the profiler is disabled; set " \
                "config.apply_env_overrides_when_disabled = true to apply them anyway"
    }.freeze

    # File format: { "KEY" => { "value" => "...", "original" => "..." } }
    # Sentinels for "value":
    #   DELETED_SENTINEL  → ENV.delete(key)
    #   RESTORE_SENTINEL  → every process that applied the key puts back the value it had before
    #                       (apply!). The entry carries "reset_at" and stays RESTORE_TTL seconds,
    #                       so that each Sidekiq process and Puma worker sees it, not only the first.

    # How long a RESTORE entry stays in the file. A process that runs no job for longer keeps the
    # override until it restarts.
    RESTORE_TTL = 7 * 24 * 60 * 60

    # How old the overrides file must be before apply! keeps its content between calls
    # (cached_overrides).
    CACHE_SETTLE_SECONDS = 2

    def initialize
      # What ENV held in this process before set, delete or apply! changed a key. Where the
      # overrides are blocked, a reset restores these and never the file's "original" values,
      # which come from whatever machine wrote the file. apply! restores these too, so it knows
      # which keys this process changed and has to put back.
      @process_originals = {}
      @process_originals_lock = Mutex.new
      # [signature of the file, parsed overrides] as apply! last read them.
      @cached_overrides = nil
      @skipped_keys_logged = nil
    end

    def set(key, value)
      # Before the file is written: an entry ENV cannot hold would fail in every process that
      # applies it.
      if (reason = EnvKeyPolicy.value_rejection(key, value))
        raise Error, "could not set #{key}: #{reason}"
      end

      surfacing("set #{key}") do
        remember_process_original(key)
        update_overrides do |overrides|
          overrides[key] = { "value" => value.to_s, "original" => original_for(overrides, key) }
        end
      end
    end

    def delete(key)
      surfacing("delete #{key}") do
        remember_process_original(key)
        update_overrides do |overrides|
          overrides[key] = { "value" => DELETED_SENTINEL, "original" => original_for(overrides, key) }
        end
      end
    end

    # Returns whether ENV was written in this process.
    def reset(key)
      entry = nil
      surfacing("reset #{key}") do
        update_overrides do |overrides|
          entry = overrides[key]
          # Keep a RESTORE entry so Sidekiq workers pick it up on next job, but remove the key
          # entirely if it is blocked by EnvKeyPolicy: refusing to restore protected keys
          # applies even when reading from persisted overrides.
          if entry
            overrides[key] = EnvKeyPolicy.allowed?(key) ? restore_entry(entry["original"]) : nil
            overrides.delete(key) if overrides[key].nil?
          end
        end
      end

      # Apply immediately to the current (web) process
      restore_env(key, entry, blocked: blocked_reason)
    end

    def reset_all
      originals = {}
      surfacing("reset the overrides") do
        update_overrides do |overrides|
          overrides.each do |key, entry|
            # Already reset: its reset_at stays, so that it still expires.
            next if restore_entry?(entry)

            # Remove keys blocked by EnvKeyPolicy entirely instead of leaving a RESTORE sentinel,
            # preventing persisted overrides from restoring protected variables.
            unless EnvKeyPolicy.allowed?(key)
              originals[key] = nil
              overrides.delete(key)
              next
            end

            originals[key] = entry.is_a?(Hash) ? entry["original"] : nil
            # Leave a RESTORE sentinel for Sidekiq workers to pick up
            overrides[key] = restore_entry(originals[key])
          end
        end
      end

      # Apply immediately to the current (web) process
      blocked = blocked_reason
      originals.each { |key, original| restore_env(key, { "original" => original }, blocked: blocked) }
    end

    # Why the persisted overrides must not reach ENV in this process, or nil when they may.
    def blocked_reason
      return :production if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.production?

      config = Profiler.configuration
      return :disabled unless config.enabled || config.apply_env_overrides_when_disabled

      nil
    end

    # Applies the overrides at boot, or says once in the log why they are left out. The message
    # carries the file and the number of keys only, never a key or a value.
    def apply_at_boot!(logger)
      reason = blocked_reason
      return apply! unless reason
      return if @boot_warning_logged

      count = all_overrides.size
      return if count.zero?

      @boot_warning_logged = true
      noun, verb = count == 1 ? %w[override was] : %w[overrides were]
      Profiler.log_warn("#{count} persisted environment #{noun} in #{override_file_path} " \
                        "#{verb} not applied: #{BLOCKED_REASONS.fetch(reason)}.", logger: logger)
    rescue => e
      Profiler.log_error("EnvOverrideStore: failed to check overrides at boot", e)
    end

    # Set by the test runner in the environment of the test process, to which it already gave
    # the admitted overrides only (TestRunner::Runner.build_env).
    TEST_RUNNER_CHILD_ENV = EnvKeyPolicy::TEST_RUNNER_CHILD_ENV
    RESERVED_KEY_ERROR = EnvKeyPolicy::RESERVED_KEY_ERROR

    # The env tools may not set or delete the test runner marker, whatever its case.
    def self.reserved_key?(key)
      EnvKeyPolicy.reserved?(key)
    end

    # Runs before every Sidekiq job and console line: the file is parsed again only when it was
    # replaced or changed since the last call (cached_overrides). Each key is applied on its own,
    # so that a key that cannot be written leaves the others applied. A key EnvKeyPolicy refuses,
    # or a value ENV cannot hold, written by a version that did not check them, is left out.
    def apply!
      return if ENV[TEST_RUNNER_CHILD_ENV] == "1"
      return if blocked_reason

      skipped = []
      cached_overrides.each do |key, entry|
        unless applicable?(key, entry)
          skipped << key
          next
        end

        apply_entry(key, entry)
      rescue StandardError => e
        Profiler.log_error("EnvOverrideStore: failed to apply an override", e)
      end
      log_skipped_keys(skipped)
    rescue => e
      Profiler.log_error("EnvOverrideStore: failed to apply overrides", e)
    end

    # Returns active overrides (excludes RESTORE entries, already being reverted)
    # A file that does not parse reads as no override; one that cannot be read raises Error.
    def all_overrides
      surfacing("read the overrides") do
        load_overrides.reject do |_, entry|
          value = entry.is_a?(Hash) ? entry["value"] : entry
          value == RESTORE_SENTINEL
        end.transform_values do |entry|
          entry.is_a?(Hash) ? entry : { "value" => entry, "original" => nil }
        end
      end
    end

    def clear
      surfacing("clear the overrides") { with_lock { FileUtils.rm_f(override_file_path) } }
    end

    private

    # The message names the file relative to tmp_path, and an Errno by its description only: it
    # goes back to the Env tab, the MCP tools and the test runner output, without absolute paths.
    def surfacing(action)
      yield
    rescue Error
      raise
    rescue StandardError => e
      reason = e.is_a?(SystemCallError) ? e.class.new.message : e.class.name
      raise Error, "could not #{action} in env_overrides.json under tmp_path: #{reason}"
    end

    def applicable?(key, entry)
      return false unless EnvKeyPolicy.allowed?(key)

      value = entry.is_a?(Hash) ? entry["value"] : entry
      EnvKeyPolicy.value_rejection(key, value).nil?
    end

    def apply_entry(key, entry)
      value = entry.is_a?(Hash) ? entry["value"] : entry

      if value == RESTORE_SENTINEL
        restore_applied(key)
        return
      end

      remember_process_original(key)
      value == DELETED_SENTINEL ? ENV.delete(key) : ENV[key] = value
    end

    # A RESTORE entry stays in the file for every process: this one puts the key back only if it
    # changed it, once, to the value it had before. A process that never applied the override has
    # nothing to restore.
    def restore_applied(key)
      changed_here, original = @process_originals_lock.synchronize do
        [@process_originals.key?(key), @process_originals.delete(key)]
      end
      return unless changed_here

      original.nil? ? ENV.delete(key) : ENV[key] = original
    end

    # Says once per set of keys how many were left out, never which: the log may be shared.
    def log_skipped_keys(skipped)
      return if skipped.empty? || @skipped_keys_logged == skipped

      @skipped_keys_logged = skipped
      noun = skipped.size == 1 ? "override was" : "overrides were"
      Profiler.log_warn("#{skipped.size} persisted environment #{noun} not applied: the name is not " \
                        "a valid environment variable name, or one the profiler does not change, " \
                        "or the value holds a NUL byte.")
    end

    def restore_entry(original)
      { "value" => RESTORE_SENTINEL, "original" => original, "reset_at" => Time.now.to_i }
    end

    def restore_entry?(entry)
      entry.is_a?(Hash) && entry["value"] == RESTORE_SENTINEL
    end

    # RESTORE entries older than RESTORE_TTL go when the file is next written. One written by an
    # earlier version, with no reset_at, starts its delay now.
    def expire_restore_entries(overrides)
      now = Time.now.to_i
      overrides.delete_if do |_key, entry|
        next false unless restore_entry?(entry)

        reset_at = entry["reset_at"]
        unless reset_at.is_a?(Integer)
          entry["reset_at"] = now
          next false
        end
        now - reset_at > RESTORE_TTL
      end
    end

    def remember_process_original(key)
      @process_originals_lock.synchronize do
        @process_originals[key] = ENV[key] unless @process_originals.key?(key)
      end
    end

    # Puts a reset key back to its original value and returns whether ENV was written. Where the
    # overrides are blocked, or the file has no entry for the key, only a key this process
    # changed itself is touched, back to the value it had here; ENV is left alone for any other.
    def restore_env(key, file_entry, blocked:)
      changed_here, process_original = @process_originals_lock.synchronize do
        [@process_originals.key?(key), @process_originals.delete(key)]
      end
      from_process = blocked || file_entry.nil?
      return false if from_process && !changed_here

      original = from_process ? process_original : file_entry["original"]
      # A name ENV cannot hold ("A=B"), written by a version that did not check the names: its
      # entry is reset in the file, and there is nothing to put back here.
      return false unless EnvKeyPolicy.valid_name?(key)
      return false if EnvKeyPolicy.value_rejection(key, original)
      # Do not restore environment variables blocked by EnvKeyPolicy: refusal to restore a
      # protected key (DATABASE_URL, RUBYOPT, etc.) applies even when reloading persisted
      # overrides from file, preventing bypasses through legacy override files.
      return false unless EnvKeyPolicy.allowed?(key)

      original.nil? ? ENV.delete(key) : ENV[key] = original
      true
    end

    def original_for(overrides, key)
      overrides.key?(key) ? overrides[key]["original"] : ENV[key]
    end

    def override_file_path
      Profiler.configuration.tmp_path.join("env_overrides.json")
    end

    def load_overrides
      path = override_file_path
      return {} unless File.exist?(path)

      parse_overrides(File.read(path))
    end

    def parse_overrides(content)
      parsed = JSON.parse(content)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    # load_overrides for apply!, without reading the file again while it is the same file.
    #
    # The signature (inode, device, mtime, size) alone can miss a write: ext4 hands the inode the
    # rename freed to the next temporary file, and two writes of the same size within one tick of
    # the mtime clock then look identical, the stale value kept until the file is written again.
    # So the content is cached only once the file has settled: its mtime at least
    # CACHE_SETTLE_SECONDS in the past. Any later write is then at least that much younger, and
    # gets another mtime on any file system whose mtime tick is shorter (2 seconds on FAT, the
    # coarsest). A file written less than that ago is read at each call, which costs a read only
    # during the seconds after a change. A write between the stat and the read caches the new
    # content under the old signature: the next call sees another mtime and reads again.
    def cached_overrides
      path = override_file_path
      stat = File.stat(path)
      signature = [path.to_s, stat.ino, stat.dev, stat.mtime, stat.size]
      cached = @cached_overrides
      return cached[1] if cached && cached[0] == signature

      overrides = parse_overrides(File.read(path)).freeze
      @cached_overrides = settled?(stat) ? [signature, overrides] : nil
      overrides
    rescue Errno::ENOENT
      @cached_overrides = nil
      {}
    end

    def settled?(stat)
      Time.now - stat.mtime >= CACHE_SETTLE_SECONDS
    end

    # Reads, changes and writes the file under the lock, so that the web process, its threads and
    # the Sidekiq processes never save over each other's changes. The file is removed when the
    # block leaves it empty.
    def update_overrides
      with_lock do
        overrides = load_overrides
        yield overrides
        expire_restore_entries(overrides)
        overrides.empty? ? FileUtils.rm_f(override_file_path) : save_overrides(overrides)
      end
    end

    # An exclusive flock on a file next to the overrides file. Not reentrant: never nest it.
    def with_lock
      path = override_file_path
      Storage::PrivateFiles.tmp_dir
      Storage::PrivateFiles.open("#{path}.lock") do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    # Written to a temporary file then renamed over the old one, so that a reader never sees a
    # half-written file, which would parse as no override at all.
    def save_overrides(overrides)
      Storage::PrivateFiles.write(override_file_path, JSON.generate(overrides))
    end
  end
end
