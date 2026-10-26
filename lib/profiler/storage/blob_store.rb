# frozen_string_literal: true

require "fileutils"
require "json"
require "set"
require_relative "private_files"
require_relative "token"

module Profiler
  module Storage
    # Large collector payloads of the SQLite store, one directory per profile token and one JSON
    # file per collector. A token or a name that is not one the gem writes is never a path: reads
    # find nothing and writes are refused.
    class BlobStore
      NAME_FORMAT = /\A[a-z0-9_]+\z/
      # A save writes its blobs before its row: prune leaves the directories this recent alone.
      PRUNE_GRACE = 60

      def initialize(path)
        @path = path.to_s
        PrivateFiles.mkdir(@path)
      end

      def write(token, collector_name, data)
        Token.validate!(token)
        raise ArgumentError, "invalid blob name: #{collector_name.inspect[0, 80]}" unless valid_name?(collector_name)

        dir = token_dir(token)
        PrivateFiles.mkdir(dir)
        PrivateFiles.write(File.join(dir, "#{collector_name}.json"), JSON.generate(data))
      end

      def read(token, collector_name)
        return nil unless valid?(token, collector_name)

        file = File.join(token_dir(token), "#{collector_name}.json")
        return nil unless File.exist?(file)

        JSON.parse(File.read(file))
      rescue => e
        Profiler.log_error("BlobStore: could not read #{token}/#{collector_name}", e)
        nil
      end

      def delete(token)
        return unless Token.valid?(token)

        dir = token_dir(token)
        FileUtils.rm_rf(dir) if File.directory?(dir)
      end

      # Removes one blob of token, and its directory once it holds no other.
      def delete_blob(token, collector_name)
        return unless valid?(token, collector_name)

        dir = token_dir(token)
        FileUtils.rm_f(File.join(dir, "#{collector_name}.json"))
        Dir.rmdir(dir) if File.directory?(dir) && Dir.empty?(dir)
      rescue SystemCallError => e
        Profiler.log_error("BlobStore: could not delete #{token}/#{collector_name}", e)
      end

      # Removes the directories of the tokens not in except_tokens: those whose row was deleted
      # outside the store, or that a failed save left behind. Only the directories named as a
      # token and unchanged for grace seconds are considered.
      def prune(except_tokens, grace: PRUNE_GRACE)
        keep = except_tokens.to_set
        cutoff = Time.now - grace
        Dir.each_child(@path) do |name|
          next if !Token.valid?(name) || keep.include?(name)

          dir = token_dir(name)
          stat = File.lstat(dir)
          FileUtils.rm_rf(dir) if stat.directory? && stat.mtime < cutoff
        rescue Errno::ENOENT
          # Normal race between concurrent workers
        rescue SystemCallError => e
          Profiler.log_error("BlobStore: could not prune #{name}", e)
        end
      rescue SystemCallError => e
        Profiler.log_error("BlobStore: could not prune #{@path}", e)
      end

      def exists?(token, collector_name)
        return false unless valid?(token, collector_name)

        File.exist?(File.join(token_dir(token), "#{collector_name}.json"))
      end

      private

      def valid?(token, collector_name)
        Token.valid?(token) && valid_name?(collector_name)
      end

      def valid_name?(collector_name)
        collector_name.is_a?(String) && NAME_FORMAT.match?(collector_name)
      end

      def token_dir(token)
        File.join(@path, token)
      end
    end
  end
end
