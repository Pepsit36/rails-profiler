# frozen_string_literal: true

require "pathname"
require_relative "local_request"
require_relative "allocation_counter"

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

    # Options whose default depends on the Rails environment: the railtie sets them only when
    # the application has not assigned them itself (see #default).
    RAILS_DEFAULTED = %i[enabled storage track_tests max_profiles].freeze

    BACKEND_LOCK = Mutex.new

    # The hosts earlier versions always left out of the outbound HTTP tab. Add them back with
    # config.http_skip_hosts += Profiler::Configuration::LOCAL_HTTP_HOSTS.
    LOCAL_HTTP_HOSTS = [/\A127\.0\.0\.1\z/, /\Alocalhost\z/i, /\A::1\z/].freeze

    attr_accessor :storage_options, :collectors,
                  :skip_paths, :slow_query_threshold, :max_queries_warning, :sql_backtrace,
                  :track_memory, :allocated_objects_warning_threshold,
                  :mcp_enabled, :mcp_transport, :mcp_port,
                  :authorization_mode, :extension_cors_enabled,
                  :cors_allowed_origins, :api_forgery_protection, :frame_ancestors,
                  :track_ajax, :ajax_skip_paths,
                  :track_http, :slow_http_threshold, :http_skip_hosts, :http_backtrace_depth,
                  :track_jobs,
                  :track_console,
                  :apply_env_overrides_when_disabled, :restrict_storage_permissions,
                  :test_runner_allow_undiscovered_files,
                  :track_mailers, :capture_mail_body, :sanitize_mailer_recipients, :mailer_skip_actions,
                  :compress_bodies, :compress_body_threshold, :max_captured_body_bytes,
                  :redact_sensitive_data, :filter_parameters, :env_allowlist,
                  :name, :master_url, :self_url,
                  :cluster_heartbeat_interval, :cluster_offline_threshold,
                  :cluster_master, :cluster_secret, :cluster_require_secret,
                  :cluster_allow_insecure_http, :logger

    attr_reader :authorize_block, :enabled, :track_tests, :max_profiles

    def initialize
      @assigned = []
      @enabled = false
      @storage = :memory
      @storage_options = {}
      @collectors = []
      @skip_paths = [%r{^/_profiler}, /\.well-known/, /favicon\.ico/, /manifest\.json/]
      @slow_query_threshold = 100 # milliseconds
      @max_queries_warning = 50
      # Where each query comes from: :first_and_slow captures the caller the first time a
      # statement runs in the request and for every slow query, :all for every query (as earlier
      # versions did, about 0.1 ms each), :none never.
      @sql_backtrace = :first_and_slow
      @track_memory = true
      # Not compared with anything yet. The default is the former 100 MB memory threshold read
      # as the objects it stood for.
      @allocated_objects_warning_threshold = 100 * 1024 * 1024 / AllocationCounter::LEGACY_BYTES_PER_OBJECT
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
      # Every host whose outbound calls are left out (Strings and Regexps matched against the host).
      # The profiler's own calls (cluster, slave proxy) are never recorded, whatever this says.
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
      # The request and response bodies kept in a profile stop at this many bytes; the
      # application still reads and sends all of them. nil keeps whole bodies.
      @max_captured_body_bytes = 256 * 1024
      @redact_sensitive_data = true
      @filter_parameters = DEFAULT_FILTER_PARAMETERS.dup
      @env_allowlist = DEFAULT_ENV_ALLOWLIST.dup
      @tmp_path = nil
      # The profiler's directories 0700 and files 0600 (Profiler::Storage::PrivateFiles). false
      # leaves the modes to the umask, for a web process and workers running under two users.
      @restrict_storage_permissions = true
      @name = nil
      @master_url = nil
      @self_url = nil
      @cluster_heartbeat_interval = 15
      @cluster_offline_threshold = 60
      # Cluster security: see Profiler::Cluster::Security and the Cluster section of the README.
      @cluster_master = false
      @cluster_secret = nil
      @cluster_require_secret = true
      @cluster_allowed_slave_urls = []
      @cluster_allow_insecure_http = false
      # Where the profiler's own errors go (Profiler.log): Rails.logger when nil, or $stderr when
      # there is none.
      @logger = nil
    end

    # Always a Pathname, whether set from a String or left to its default.
    def tmp_path
      @tmp_path || default_tmp_path
    end

    def tmp_path=(value)
      @tmp_path = value.nil? ? nil : Pathname.new(value)
    end

    attr_reader :cluster_allowed_slave_urls

    # Deprecated: the figure it was meant for was never a byte count (see AllocationCounter).
    # Read and written as allocated_objects_warning_threshold times the bytes per object the
    # former figure used.
    def memory_warning_threshold
      @allocated_objects_warning_threshold&.*(AllocationCounter::LEGACY_BYTES_PER_OBJECT)
    end

    def memory_warning_threshold=(bytes)
      Profiler.log_warn("memory_warning_threshold is deprecated, set allocated_objects_warning_threshold " \
                        "(a number of objects) instead")
      @allocated_objects_warning_threshold = bytes && bytes / AllocationCounter::LEGACY_BYTES_PER_OBJECT
    end

    # :any, or a list of slave URLs and anchored Regexp patterns (see Profiler::Cluster::Security).
    # A Regexp that is not anchored with \A and \z is refused here, at boot, rather than ignored.
    def cluster_allowed_slave_urls=(value)
      unless value == :any
        require_relative "cluster/security"
        Array(value).grep(Regexp).each do |pattern|
          unless Profiler::Cluster::Security.anchored_pattern?(pattern)
            raise ArgumentError, "config.cluster_allowed_slave_urls: #{pattern.inspect} must start with \\A and " \
                                 "end with \\z, so that it matches the whole slave URL"
          end

          begin
            Profiler::Cluster::Security.whole_url_pattern(pattern)
          rescue RegexpError => e
            raise ArgumentError, "config.cluster_allowed_slave_urls: #{pattern.inspect} cannot be matched against " \
                                 "the whole slave URL (#{e.message}); an x-mode comment must not hide the \\z"
          end
        end
      end
      @cluster_allowed_slave_urls = value
    end

    def enabled=(value)
      @assigned |= [:enabled]
      @enabled = value
    end

    def track_tests=(value)
      @assigned |= [:track_tests]
      @track_tests = value
    end

    # How many profiles a store keeps, the oldest evicted first; nil for no cap on the count (the
    # memory store still keeps 100). The railtie leaves it nil in the test environment.
    def max_profiles=(value)
      @assigned |= [:max_profiles]
      @max_profiles = value
    end

    # Sets one of RAILS_DEFAULTED to value unless the application assigned it, in
    # config/application.rb for instance, which runs before the railtie's initializers.
    def default(option, value)
      raise ArgumentError, "#{option} has no Rails default" unless RAILS_DEFAULTED.include?(option)
      return if @assigned.include?(option)

      public_send("#{option}=", value)
      @assigned.delete(option)
    end

    def slave?
      !master_url.nil? && !master_url.empty?
    end

    def master?
      !slave?
    end

    # Whether this node serves the master-side cluster routes (register, heartbeat, slaves and
    # the slave proxy). Read on each request by the route constraints.
    def cluster_master?
      cluster_master ? true : false
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
      @assigned |= [:storage]
      @storage = value
      @storage_backend = nil
    end

    # Under a lock of its own, for a caller that asks the configuration directly; Profiler.storage
    # takes it inside its own, always in that order.
    def storage_backend
      @storage_backend || BACKEND_LOCK.synchronize { @storage_backend ||= build_storage_backend }
    end

    private

    def default_tmp_path
      if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
        Rails.root.join("tmp", "rails-profiler")
      else
        Pathname.new(File.expand_path("tmp/rails-profiler", Dir.pwd))
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
