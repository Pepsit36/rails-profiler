# frozen_string_literal: true

require "json"
require "fileutils"

module Profiler
  class EnvOverrideStore
    DELETED_SENTINEL = "__profiler_deleted__"
    RESTORE_SENTINEL = "__profiler_restore__"

    # File format: { "KEY" => { "value" => "...", "original" => "..." } }
    # Sentinels for "value":
    #   DELETED_SENTINEL  → ENV.delete(key)
    #   RESTORE_SENTINEL  → restore ENV[key] to "original" (cleaned up after apply!)

    def set(key, value)
      overrides = load_overrides
      original = original_for(overrides, key)
      overrides[key] = { "value" => value.to_s, "original" => original }
      save_overrides(overrides)
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to set #{key}: #{e.message}"
    end

    def delete(key)
      overrides = load_overrides
      original = original_for(overrides, key)
      overrides[key] = { "value" => DELETED_SENTINEL, "original" => original }
      save_overrides(overrides)
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to delete #{key}: #{e.message}"
    end

    def reset(key)
      overrides = load_overrides
      entry = overrides[key]
      return unless entry

      original = entry["original"]
      # Keep a RESTORE entry so Sidekiq workers pick it up on next job
      overrides[key] = { "value" => RESTORE_SENTINEL, "original" => original }
      save_overrides(overrides)

      # Apply immediately to the current (web) process
      original.nil? ? ENV.delete(key) : ENV[key] = original
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to reset #{key}: #{e.message}"
    end

    def reset_all
      overrides = load_overrides
      restore_overrides = {}

      overrides.each do |key, entry|
        original = entry.is_a?(Hash) ? entry["original"] : nil
        # Apply immediately to the current (web) process
        original.nil? ? ENV.delete(key) : ENV[key] = original
        # Leave a RESTORE sentinel for Sidekiq workers to pick up
        restore_overrides[key] = { "value" => RESTORE_SENTINEL, "original" => original }
      end

      restore_overrides.empty? ? clear : save_overrides(restore_overrides)
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to reset all: #{e.message}"
    end

    def apply!
      overrides = load_overrides
      restore_keys = []

      overrides.each do |key, entry|
        value    = entry.is_a?(Hash) ? entry["value"]    : entry
        original = entry.is_a?(Hash) ? entry["original"] : nil

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
        restore_keys.each { |k| overrides.delete(k) }
        save_overrides(overrides)
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
      FileUtils.rm_f(override_file_path)
    rescue => e
      warn "[Profiler] EnvOverrideStore: failed to clear: #{e.message}"
    end

    private

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

    def save_overrides(overrides)
      path = override_file_path
      FileUtils.mkdir_p(path.dirname)
      File.write(path, JSON.generate(overrides))
    end
  end
end
