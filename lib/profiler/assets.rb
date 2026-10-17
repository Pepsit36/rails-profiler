# frozen_string_literal: true

require "digest"

module Profiler
  # The gem's built front end files. Each is read once and kept until the file changes on disk
  # (a rebuild in development), and named by a digest of its content so that a browser that
  # cached one never keeps it past a new version of the gem.
  module Assets
    NAMES = %w[profiler.js profiler.css profiler-toolbar.js].freeze
    URL_PREFIX = "/_profiler/assets"

    Entry = Struct.new(:mtime, :content, :digest)

    @entries = {}
    @mutex = Mutex.new

    class << self
      # Where the build writes the files; the gem's own, never the application's.
      def builds_dir
        File.expand_path("../../app/assets/builds", __dir__)
      end

      # The file's content, or raises Errno::ENOENT when the assets are not built.
      def read(name)
        entry(name).content
      end

      # Short digest of the content; the gem version when the file is not built.
      def digest(name)
        entry(name).digest
      rescue Errno::ENOENT
        Digest::SHA256.hexdigest(Profiler::VERSION)[0, 12]
      end

      # The URL a page uses for the asset, carrying its digest.
      def url(name)
        "#{URL_PREFIX}/#{name}?v=#{digest(name)}"
      end

      def current?(name, version)
        version.is_a?(String) && !version.empty? && version == digest(name)
      end

      private

      def entry(name)
        raise ArgumentError, "unknown asset: #{name}" unless NAMES.include?(name)

        path = File.join(builds_dir, name)
        mtime = File.mtime(path)
        cached = @mutex.synchronize { @entries[name] }
        return cached if cached && cached.mtime == mtime

        content = File.read(path)
        fresh = Entry.new(mtime, content, Digest::SHA256.hexdigest(content)[0, 12])
        @mutex.synchronize { @entries[name] = fresh }
      end
    end
  end
end
