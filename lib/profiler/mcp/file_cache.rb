# frozen_string_literal: true

require "fileutils"
require_relative "../storage/private_files"
require_relative "../storage/token"

module Profiler
  module MCP
    # The bodies the MCP tools save on request (save_bodies), under tmp_path/mcp-cache/<token>/<name>.
    # The token comes from a profile, which a slave may have sent: one that is not a token the gem
    # issues, or a name that is not one the tools use, is refused. The cleanup only removes the
    # token directories of this cache: tmp_path also holds the profiles, the SQLite blobs and the
    # env overrides.
    class FileCache
      DIR_NAME = "mcp-cache"
      NAME_FORMAT = /\A[a-z0-9_]+\z/

      def self.base_dir
        Profiler.configuration.tmp_path.join(DIR_NAME).to_s
      end

      def self.save(token, name, content)
        return nil unless Storage::Token.valid?(token) && name.is_a?(String) && NAME_FORMAT.match?(name)

        cleanup if rand < 0.05

        dir = Storage::PrivateFiles.tmp_dir(DIR_NAME, token)
        Storage::PrivateFiles.write(dir.join(name), content)
      rescue Errno::EACCES, Errno::EROFS => e
        Profiler.log_error_once(:mcp_file_cache, "MCP: could not cache a body under tmp_path", e)
        nil
      end

      def self.cleanup(max_age: 3600)
        bd = base_dir
        return unless Dir.exist?(bd)

        Dir.children(bd).each do |entry|
          next unless Storage::Token.valid?(entry)

          dir = File.join(bd, entry)
          FileUtils.rm_rf(dir) if File.directory?(dir) && (Time.now - File.mtime(dir)) > max_age
        end
      end
    end
  end
end
