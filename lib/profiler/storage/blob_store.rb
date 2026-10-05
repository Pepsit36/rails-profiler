# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "private_files"
require_relative "token"

module Profiler
  module Storage
    # Large collector payloads of the SQLite store, one directory per profile token and one JSON
    # file per collector. A token or a name that is not one the gem writes is never a path: reads
    # find nothing and writes are refused.
    class BlobStore
      NAME_FORMAT = /\A[a-z0-9_]+\z/

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
        warn "BlobStore: failed to read #{token}/#{collector_name}: #{e.message}"
        nil
      end

      def delete(token)
        return unless Token.valid?(token)

        dir = token_dir(token)
        FileUtils.rm_rf(dir) if File.directory?(dir)
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
