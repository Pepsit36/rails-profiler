# frozen_string_literal: true

require_relative "local_request"

module Profiler
  # Header the profiler's own clients send on every request. A page on another origin cannot
  # add it without a CORS preflight, which the profiler does not grant by default, so its
  # presence proves the request is not a cross-site forgery.
  FORGERY_PROTECTION_HEADER = "X-Profiler-Request"

  class Configuration
    # Added to the application's own config.filter_parameters: the list of the
    # Rails 7.1 application template, without :email.
    DEFAULT_FILTER_PARAMETERS = %i[
      passw secret token _key crypt salt certificate otp ssn cvv cvc
    ].freeze

    # ENV variables whose values the profiler shows; every other one is listed
    # with its value masked.
    DEFAULT_ENV_ALLOWLIST = %w[
      RAILS_ENV RACK_ENV NODE_ENV RAILS_LOG_LEVEL RAILS_LOG_TO_STDOUT RAILS_SERVE_STATIC_FILES
      RAILS_MAX_THREADS RAILS_MIN_THREADS WEB_CONCURRENCY PORT PIDFILE
      LANG LANGUAGE LC_ALL LC_CTYPE TZ HOME PWD PATH SHELL USER HOSTNAME TERM
      RUBY_VERSION RUBYOPT RUBY_YJIT_ENABLE MALLOC_ARENA_MAX
      BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_WITHOUT GEM_HOME GEM_PATH BOOTSNAP_CACHE_DIR
    ].freeze

    attr_accessor :enabled, :storage_options, :collectors,
                  :skip_paths, :slow_query_threshold, :max_queries_warning,
                  :track_memory, :memory_warning_threshold,
                  :mcp_enabled, :mcp_transport, :mcp_port,
                  :authorization_mode, :max_profiles, :extension_cors_enabled,
                  :cors_allowed_origins, :api_forgery_protection, :frame_ancestors,
                  :track_ajax, :ajax_skip_paths,
                  :track_http, :slow_http_threshold, :http_skip_hosts, :http_backtrace_depth,
                  :track_jobs,
                  :track_console,
                  :apply_env_overrides_when_disabled,
                  :track_tests, :test_runner_allow_undiscovered_files,
                  :track_mailers, :capture_mail_body, :sanitize_mailer_recipients, :mailer_skip_actions,
                  :compress_bodies, :compress_body_threshold,
                  :redact_sensitive_data, :filter_parameters, :env_allowlist,
                  :name, :master_url, :self_url,
                  :cluster_heartbeat_interval, :cluster_offline_threshold

    attr_writer :tmp_path

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
      @authorization_mode = :allow_local
      @authorize_block = nil
      @max_profiles = 100
      @extension_cors_enabled = false
      @cors_allowed_origins = []
      @api_forgery_protection = true
      # The Chrome extension shows the profiler in a DevTools panel: an iframe inside a
      # chrome-extension:// page, itself inside the devtools://devtools front end. Chrome
      # checks frame-ancestors against every ancestor, so both schemes are needed.
      @frame_ancestors = ["'self'", "chrome-extension:", "devtools:"]
      @track_ajax = true
      @ajax_skip_paths = [/^\/_profiler/]
      @track_http = true
      @slow_http_threshold = 500 # milliseconds
      @http_skip_hosts = []
      @http_backtrace_depth = 40
      @track_jobs = true
      @track_console = true
      @apply_env_overrides_when_disabled = false
      @track_tests = false
      # The test runner only runs the files listed by its discovery. true restores the
      # previous behavior: any file under the Rails root.
      @test_runner_allow_undiscovered_files = false
      @track_mailers = true
      @capture_mail_body = false
      @sanitize_mailer_recipients = false
      @mailer_skip_actions = []
      @compress_bodies = true
      @compress_body_threshold = 10 * 1024 # 10 KB
      @redact_sensitive_data = true
      @filter_parameters = DEFAULT_FILTER_PARAMETERS.dup
      @env_allowlist = DEFAULT_ENV_ALLOWLIST.dup
      @tmp_path = nil
      @name = nil
      @master_url = nil
      @self_url = nil
      @cluster_heartbeat_interval = 15
      @cluster_offline_threshold = 60
    end

    def tmp_path
      @tmp_path || default_tmp_path
    end

    def slave?
      !master_url.nil? && !master_url.empty?
    end

    def master?
      !slave?
    end

    # Whether /_profiler/mcp is routed. The stdio transport (rake profiler:mcp) does not depend
    # on it.
    def mcp_http_enabled?
      mcp_enabled && mcp_transport.to_s == "http" ? true : false
    end

    def resolved_name
      @name || (defined?(Rails) ? Rails.application.class.module_parent_name.underscore : "profiler")
    end

    def authorize_with(&block)
      @authorize_block = block
    end

    def authorized?(request)
      case @authorization_mode
      when :allow_all
        true
      when :allow_local
        reason = LocalRequest.denial_reason(request)
        return true if reason.nil?

        LocalRequest.warn_once(reason)
        false
      when :allow_authorized
        @authorize_block ? @authorize_block.call(request) : false
      else
        false
      end
    end

    def storage
      @storage
    end

    def storage=(value)
      @storage = value
      @storage_backend = nil
    end

    def storage_backend
      @storage_backend ||= build_storage_backend
    end

    private

    def default_tmp_path
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("tmp", "rails-profiler")
      else
        File.expand_path("tmp/rails-profiler", Dir.pwd)
      end
    end

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
