# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "base_store"
require_relative "../models/profile"

module Profiler
  module Storage
    class FileStore < BaseStore
      def initialize(options = {})
        @path = options[:path] || default_path
        @max_size = options[:max_size] || 100 * 1024 * 1024 # 100 MB
        ensure_directory_exists
      end

      def save(token, profile)
        file_path = profile_file_path(token)
        File.write(file_path, profile.to_json)
        cleanup_if_needed
        token
      end

      def load(token)
        file_path = profile_file_path(token)
        return nil unless File.exist?(file_path)

        json_data = File.read(file_path)
        Models::Profile.from_json(json_data)
      rescue => e
        warn "Failed to load profile #{token}: #{e.message}"
        nil
      end

      def list(limit: 50, offset: 0)
        profile_files
          .sort_by { |f| File.mtime(f) }
          .reverse
          .drop(offset)
          .take(limit)
          .map { |f| load(File.basename(f, ".json")) }
          .compact
      end

      def cleanup(older_than: 24 * 60 * 60)
        cutoff_time = Time.now - older_than
        profile_files.each do |file|
          File.delete(file) if File.mtime(file) < cutoff_time
        rescue => e
          warn "Failed to delete profile file #{file}: #{e.message}"
        end
      end

      def find_by_parent(parent_token)
        profile_files
          .map { |f| load(File.basename(f, ".json")) }
          .compact
          .select { |profile| profile.parent_token == parent_token }
          .sort_by { |profile| profile.started_at }
      end

      private

      def default_path
        if defined?(Rails)
          Rails.root.join("tmp", "profiler")
        else
          File.expand_path("tmp/profiler", Dir.pwd)
        end
      end

      def ensure_directory_exists
        FileUtils.mkdir_p(@path) unless File.directory?(@path)
      end

      def profile_file_path(token)
        File.join(@path, "#{token}.json")
      end

      def profile_files
        Dir.glob(File.join(@path, "*.json"))
      end

      def cleanup_if_needed
        total_size = profile_files.sum { |f| File.size(f) }
        return if total_size < @max_size

        # Delete oldest files until we're under the limit
        profile_files
          .sort_by { |f| File.mtime(f) }
          .each do |file|
            File.delete(file)
            total_size -= File.size(file)
            break if total_size < @max_size * 0.8
          rescue => e
            warn "Failed to delete profile file #{file}: #{e.message}"
          end
      end
    end
  end
end
