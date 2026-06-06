# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "base_store"
require_relative "../models/profile"

module Profiler
  module Storage
    # File-based profile storage backend. Persists each profile as a JSON file
    # under tmp_path and evicts the oldest files when total size exceeds max_size.
    class FileStore < BaseStore
      def initialize(options = {})
        super()
        @path = options[:path] || default_path
        @max_size = options[:max_size] || (100 * 1024 * 1024) # 100 MB
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
      rescue StandardError => e
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
        rescue Errno::ENOENT
          nil
        end
      end

      def find_by_parent(parent_token)
        profile_files
          .map { |f| load(File.basename(f, ".json")) }
          .compact
          .select { |profile| profile.parent_token == parent_token }
          .sort_by(&:started_at)
      end

      def delete(token)
        FileUtils.rm_f(profile_file_path(token))
      end

      def clear(type: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        if type.nil?
          profile_files.each do |f|
            File.delete(f)
          rescue StandardError
            nil
          end
        else
          profile_files.each do |f|
            profile = load(File.basename(f, ".json"))
            File.delete(f) if profile&.profile_type == type.to_s
          rescue StandardError
            nil
          end
        end
      end

      private

      def default_path
        Profiler.configuration.tmp_path
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

      def cleanup_if_needed # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        total_size = profile_files.sum do |f|
          File.size(f)
        rescue Errno::ENOENT
          0
        end
        return if total_size < @max_size

        sorted = profile_files.sort_by do |f|
          File.mtime(f)
        rescue Errno::ENOENT
          Time.now
        end

        sorted.each do |file|
          file_size = File.size(file)
          File.delete(file)
          total_size -= file_size
          break if total_size < @max_size * 0.8
        rescue Errno::ENOENT
          nil
        end
      end
    end
  end
end
