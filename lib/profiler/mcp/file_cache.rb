# frozen_string_literal: true

require "fileutils"

module Profiler
  module MCP
    class FileCache
      BASE_DIR = "/tmp/rails-profiler"

      def self.save(token, name, content)
        cleanup if rand < 0.05

        dir = File.join(BASE_DIR, token)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, name)
        File.write(path, content)
        path
      rescue Errno::EACCES, Errno::EROFS
        nil
      end

      def self.cleanup(max_age: 3600)
        return unless Dir.exist?(BASE_DIR)

        Dir.glob(File.join(BASE_DIR, "*")).each do |dir|
          FileUtils.rm_rf(dir) if File.directory?(dir) && (Time.now - File.mtime(dir)) > max_age
        end
      end
    end
  end
end
