# frozen_string_literal: true

module Profiler
  class Configuration
    attr_accessor :enabled, :storage, :storage_options, :collectors,
                  :skip_paths, :slow_query_threshold, :max_queries_warning,
                  :track_memory, :memory_warning_threshold,
                  :mcp_enabled, :mcp_transport, :mcp_port,
                  :authorization_mode, :max_profiles, :extension_cors_enabled,
                  :track_ajax, :ajax_skip_paths,
                  :track_http, :slow_http_threshold, :http_skip_hosts,
                  :track_jobs

    attr_reader :authorize_block

    def initialize
      @enabled = false
      @storage = :memory
      @storage_options = {}
      @collectors = []
      @skip_paths = [%r{^/_profiler}, /\.well-known/, /favicon\.ico/, /manifest\.json/]
      @slow_query_threshold = 100 # milliseconds
      @max_queries_warning = 50
      @track_memory = true
      @memory_warning_threshold = 100 * 1024 * 1024 # 100 MB
      @mcp_enabled = false
      @mcp_transport = :stdio
      @mcp_port = 3001
      @authorization_mode = :allow_all
      @authorize_block = nil
      @max_profiles = 100
      @extension_cors_enabled = true
      @track_ajax = true
      @ajax_skip_paths = [/^\/_profiler/]
      @track_http = true
      @slow_http_threshold = 500 # milliseconds
      @http_skip_hosts = []
      @track_jobs = true
    end

    def authorize_with(&block)
      @authorize_block = block
    end

    def authorized?(request)
      case @authorization_mode
      when :allow_all
        true
      when :allow_authorized
        @authorize_block ? @authorize_block.call(request) : false
      else
        false
      end
    end

    def storage_backend
      @storage_backend ||= build_storage_backend
    end

    private

    def build_storage_backend
      case @storage
      when :memory
        require_relative "storage/memory_store"
        Storage::MemoryStore.new(@storage_options)
      when :file
        require_relative "storage/file_store"
        Storage::FileStore.new(@storage_options)
      when :redis
        require_relative "storage/redis_store"
        Storage::RedisStore.new(@storage_options)
      when :sqlite
        require_relative "storage/sqlite_store"
        Storage::SqliteStore.new(@storage_options)
      else
        raise Error, "Unknown storage backend: #{@storage}"
      end
    end
  end
end
