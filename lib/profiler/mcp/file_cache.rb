# frozen_string_literal: true

require "fileutils"

module Profiler
  module MCP
    class FileCache
      def self.base_dir
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.join("tmp", "rails-profiler").to_s
        else
          File.join(Dir.pwd, "tmp", "rails-profiler")
        end
      end

      def self.save(token, name, content)
        cleanup if rand < 0.05

        dir = File.join(base_dir, token)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, name)
        File.write(path, content)
        path
      rescue Errno::EACCES, Errno::EROFS
        nil
      end

      def self.cleanup(max_age: 3600)
        bd = base_dir
        return unless Dir.exist?(bd)

        Dir.glob(File.join(bd, "*")).each do |dir|
          FileUtils.rm_rf(dir) if File.directory?(dir) && (Time.now - File.mtime(dir)) > max_age
        end
      end
    end
  end
end
