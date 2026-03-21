# frozen_string_literal: true

require "fileutils"
require "json"

module Profiler
  module Storage
    class BlobStore
      def initialize(path)
        @path = path
        FileUtils.mkdir_p(@path)
      end

      def write(token, collector_name, data)
        dir = token_dir(token)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "#{collector_name}.json"), JSON.generate(data))
      end

      def read(token, collector_name)
        file = File.join(token_dir(token), "#{collector_name}.json")
        return nil unless File.exist?(file)

        JSON.parse(File.read(file))
      rescue => e
        warn "BlobStore: failed to read #{token}/#{collector_name}: #{e.message}"
        nil
      end

      def delete(token)
        dir = token_dir(token)
        FileUtils.rm_rf(dir) if File.directory?(dir)
      end

      def exists?(token, collector_name)
        File.exist?(File.join(token_dir(token), "#{collector_name}.json"))
      end

      private

      def token_dir(token)
        File.join(@path, token)
      end
    end
  end
end
