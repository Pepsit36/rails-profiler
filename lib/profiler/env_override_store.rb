# frozen_string_literal: true

require "json"
require "fileutils"

module Profiler
  class EnvOverrideStore
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
    #   RESTORE_SENTINEL  → restore ENV[key] to "original" (cleaned up after apply!)

    def initialize
      # What ENV held in this process before set, delete or apply! changed a key. Where the
      # overrides are blocked, a reset restores these and never the file's "original" values,
      # which come from whatever machine wrote the file.
      @process_originals = {}
      @process_originals_lock = Mutex.new
    end

    def set(key, value)
      remember_process_original(key)
      update_overrides do |overrides|
        overrides[key] = { "value" => value.to_s, "original" => original_for(overrides, key) }
      end
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to set #{key}: #{e.message}"
    end

    def delete(key)
      remember_process_original(key)
      update_overrides do |overrides|
        overrides[key] = { "value" => DELETED_SENTINEL, "original" => original_for(overrides, key) }
      end
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to delete #{key}: #{e.message}"
    end

    # Returns whether ENV was written in this process.
    def reset(key)
      entry = nil
      update_overrides do |overrides|
        entry = overrides[key]
        # Keep a RESTORE entry so Sidekiq workers pick it up on next job
        overrides[key] = { "value" => RESTORE_SENTINEL, "original" => entry["original"] } if entry
      end

      # Apply immediately to the current (web) process
      restore_env(key, entry, blocked: blocked_reason)
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to reset #{key}: #{e.message}"
    end

    def reset_all
      originals = {}
      update_overrides do |overrides|
        overrides.each do |key, entry|
          originals[key] = entry.is_a?(Hash) ? entry["original"] : nil
          # Leave a RESTORE sentinel for Sidekiq workers to pick up
          overrides[key] = { "value" => RESTORE_SENTINEL, "original" => originals[key] }
        end
      end

      # Apply immediately to the current (web) process
      blocked = blocked_reason
      originals.each { |key, original| restore_env(key, { "original" => original }, blocked: blocked) }
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to reset all: #{e.message}"
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
      logger&.warn("[Profiler] #{count} persisted environment #{noun} in #{override_file_path} " \
                   "#{verb} not applied: #{BLOCKED_REASONS.fetch(reason)}.")
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to check overrides at boot: #{e.message}"
    end

    # Set by the test runner in the environment of the test process, to which it already gave
    # the admitted overrides only (TestRunner::Runner.build_env).
    TEST_RUNNER_CHILD_ENV = "PROFILER_TEST_RUNNER_CHILD"
    RESERVED_KEY_ERROR = "#{TEST_RUNNER_CHILD_ENV} is reserved for the test runner"

    # The env tools may not set or delete the test runner marker, whatever its case.
    def self.reserved_key?(key)
      key.to_s.upcase == TEST_RUNNER_CHILD_ENV
    end

    def apply!
      return if ENV[TEST_RUNNER_CHILD_ENV] == "1"
      return if blocked_reason

      overrides = load_overrides
      restore_keys = []

      overrides.each do |key, entry|
        value    = entry.is_a?(Hash) ? entry["value"]    : entry
        original = entry.is_a?(Hash) ? entry["original"] : nil

        remember_process_original(key) unless value == RESTORE_SENTINEL

        case value
        when DELETED_SENTINEL
          ENV.delete(key)
        when RESTORE_SENTINEL
          original.nil? ? ENV.delete(key) : ENV[key] = original
          restore_keys << key
        else
          ENV[key] = value
        end
      end

      if restore_keys.any?
        # Read again under the lock: another writer may have changed the file since.
        update_overrides do |current|
          restore_keys.each do |k|
            entry = current[k]
            current.delete(k) if entry.is_a?(Hash) && entry["value"] == RESTORE_SENTINEL
          end
        end
      end
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to apply overrides: #{e.message}"
    end

    # Returns active overrides (excludes RESTORE entries — already being reverted)
    def all_overrides
      load_overrides.reject do |_, entry|
        value = entry.is_a?(Hash) ? entry["value"] : entry
        value == RESTORE_SENTINEL
      end.transform_values do |entry|
        entry.is_a?(Hash) ? entry : { "value" => entry, "original" => nil }
      end
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to load overrides: #{e.message}"
      {}
    end

    def clear
      with_lock { FileUtils.rm_f(override_file_path) }
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to clear: #{e.message}"
    end

    private

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

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      {}
    end

    # Reads, changes and writes the file under the lock, so that the web process, its threads and
    # the Sidekiq processes never save over each other's changes. The file is removed when the
    # block leaves it empty.
    def update_overrides
      with_lock do
        overrides = load_overrides
        yield overrides
        overrides.empty? ? FileUtils.rm_f(override_file_path) : save_overrides(overrides)
      end
    end

    # An exclusive flock on a file next to the overrides file. Not reentrant: never nest it.
    def with_lock
      path = override_file_path
      FileUtils.mkdir_p(path.dirname)
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    # Written to a temporary file then renamed over the old one, so that a reader never sees a
    # half-written file, which would parse as no override at all.
    def save_overrides(overrides)
      path = override_file_path
      tmp = "#{path}.#{Process.pid}.#{Thread.current.object_id}.tmp"
      File.write(tmp, JSON.generate(overrides))
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp
    end
  end
end
