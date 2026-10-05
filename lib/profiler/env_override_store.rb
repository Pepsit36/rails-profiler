# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "storage/private_files"

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
    #   RESTORE_SENTINEL  → restore ENV[key] to "original" (cleaned up after apply!)

    def initialize
      # What ENV held in this process before set, delete or apply! changed a key. Where the
      # overrides are blocked, a reset restores these and never the file's "original" values,
      # which come from whatever machine wrote the file.
      @process_originals = {}
      @process_originals_lock = Mutex.new
    end

    def set(key, value)
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
          # Keep a RESTORE entry so Sidekiq workers pick it up on next job
          overrides[key] = { "value" => RESTORE_SENTINEL, "original" => entry["original"] } if entry
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
            originals[key] = entry.is_a?(Hash) ? entry["original"] : nil
            # Leave a RESTORE sentinel for Sidekiq workers to pick up
            overrides[key] = { "value" => RESTORE_SENTINEL, "original" => originals[key] }
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
      logger&.warn("[Profiler] #{count} persisted environment #{noun} in #{override_file_path} " \
                   "#{verb} not applied: #{BLOCKED_REASONS.fetch(reason)}.")
    rescue => e
      Profiler.log_error("EnvOverrideStore: failed to check overrides at boot", e)
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
