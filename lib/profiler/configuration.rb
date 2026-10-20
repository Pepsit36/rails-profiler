# frozen_string_literal: true

require "pathname"
require_relative "local_request"
require_relative "allocation_counter"
require_relative "alerts/webhook"

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

    # URL schemes the source links can use. Anything else is never turned into a link.
    EDITOR_URL_SCHEMES = %w[vscode idea cursor].freeze

    attr_reader :alert_webhook_url

    attr_accessor :storage_options, :collectors,
                  :slow_query_threshold, :max_queries_warning, :sql_backtrace,
                  :track_memory, :allocated_objects_warning_threshold,
                  :alerts_enabled, :alert_webhook_timeout,
                  :mcp_enabled, :mcp_transport, :mcp_port, :mcp_read_only,
                  :authorization_mode, :extension_cors_enabled,
                  :cors_allowed_origins, :api_forgery_protection, :frame_ancestors,
                  :track_ajax, :ajax_skip_paths,
                  :track_http, :slow_http_threshold, :http_backtrace_depth,
                  :otel_enabled, :otel_service_name, :otel_otlp_endpoint,
                  :track_jobs,
                  :track_console,
                  :apply_env_overrides_when_disabled, :restrict_storage_permissions,
                  :test_runner_allow_undiscovered_files, :allow_explain_outside_development,
                  :test_runner_kill_grace_seconds,
                  :test_runner_max_output_bytes, :test_runner_max_active_runs,
                  :track_mailers, :capture_mail_body, :sanitize_mailer_recipients, :mailer_skip_actions,
                  :compress_bodies, :compress_body_threshold, :max_captured_body_bytes, :max_captured_log_bytes,
                  :redact_sensitive_data, :filter_parameters, :env_allowlist,
                  :name, :master_url, :self_url,
                  :cluster_heartbeat_interval, :cluster_offline_threshold,
                  :cluster_master, :cluster_secret, :cluster_require_secret,
                  :cluster_allow_insecure_http, :logger,
                  :collector_circuit_breaker_enabled,
                  :peers, :peer_token, :peer_allow_insecure_http,
                  :regression_duration_threshold, :regression_memory_threshold,
                  :regression_query_threshold, :regression_cache_threshold

    attr_reader :authorize_block, :enabled, :track_tests, :max_profiles, :editor_url_scheme, :editor_path_map

    def initialize
      @assigned = []
      @enabled = false
      @storage = :memory
      @storage_options = {}
      @collectors = []
      @skip_paths = [%r{\A/_profiler}, %r{\A/\.well-known/}, %r{\A/favicon\.ico\z}, %r{\A(?:/[^/]+)*/manifest\.json\z},
                     %r{\A/assets/}, %r{\A/cable(/|\z)}]
      @slow_query_threshold = 100 # milliseconds
      @max_queries_warning = 50
      # Where each query comes from: :first_and_slow captures the caller the first time a
      # statement runs in the request and for every slow query, :all for every query (as earlier
      # versions did, about 0.1 ms each), :none never.
      @sql_backtrace = :first_and_slow
      @track_memory = true
      # Threshold alerts (Profiler::Alerts): off until enabled; the webhook stays off until a URL is set.
      @alerts_enabled = false
      @alert_webhook_url = nil
      @alert_webhook_timeout = 3 # seconds, for the connection and for the answer
      @on_detection = nil
      # Not compared with anything yet. The default is the former 100 MB memory threshold read
      # as the objects it stood for.
      @allocated_objects_warning_threshold = 100 * 1024 * 1024 / AllocationCounter::LEGACY_BYTES_PER_OBJECT
      @mcp_enabled = false
      @mcp_transport = :stdio
      @mcp_port = 3001
      # true leaves out of the MCP server every tool that changes something: run_tests,
      # clear_profiles and the env tools that set, delete or reset a variable
      # (Profiler::MCP::Server::WRITE_TOOLS). Read when the server is built, at the first MCP call.
      @mcp_read_only = false
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
      # OpenTelemetry export of each profiled request as a trace. Off: nothing of OpenTelemetry is
      # loaded or touched. The opentelemetry-* gems are the application's to add to its Gemfile.
      @otel_enabled = false
      @otel_service_name = nil
      @otel_otlp_endpoint = nil
      @track_jobs = true
      @track_console = true
      @apply_env_overrides_when_disabled = false
      @track_tests = false
      # The test runner only runs the files listed by its discovery. true restores the
      # previous behavior: any file under the Rails root.
      @test_runner_allow_undiscovered_files = false
      # Explain (the Database tab button, POST /_profiler/api/explain, the explain_query MCP tool)
      # only runs in the development and test environments, even with enabled = true elsewhere:
      # PostgreSQL's EXPLAIN ANALYZE runs the query. true allows it in every environment.
      @allow_explain_outside_development = false
      # Stopping a run sends TERM to its whole process group, then KILL after this many seconds
      # if any process of the group is still there.
      @test_runner_kill_grace_seconds = 5
      # What a run keeps of its output, in bytes: the beginning, then the last quarter of this
      # once it is exceeded, with a marker in between. nil keeps everything.
      @test_runner_max_output_bytes = 5 * 1024 * 1024
      # Runs whose test process has not ended yet; another one is refused. nil for no limit.
      @test_runner_max_active_runs = 2
      @track_mailers = true
      @capture_mail_body = false
      @sanitize_mailer_recipients = false
      @mailer_skip_actions = []
      @compress_bodies = true
      @compress_body_threshold = 10 * 1024 # 10 KB
      # The request and response bodies kept in a profile stop at this many bytes; the
      # application still reads and sends all of them. nil keeps whole bodies.
      @max_captured_body_bytes = 256 * 1024
      # What a profile keeps of the lines its request logs, in bytes. nil keeps every line.
      @max_captured_log_bytes = 1024 * 1024
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
      @mcp_allowed_hosts = []
      @cluster_allow_insecure_http = false
      # Where the profiler's own errors go (Profiler.log): Rails.logger when nil, or $stderr when
      # there is none.
      @logger = nil
      # A collector that fails this many times in a row is no longer run (see
      # Profiler::Collectors::CircuitBreaker); false never stops one.
      @collector_circuit_breaker_enabled = true
      @collector_circuit_breaker_threshold = 3
      @editor_url_scheme = "vscode"
      @editor_path_map = {}
      # Other instances whose profiles can be compared with this one's: [{ name:, url: }]. The only
      # URLs the profiler ever calls to read a profile (Profiler::Peers). Empty: no outgoing call.
      @peers = []
      @peer_token = nil
      @peer_allow_insecure_http = false
      @regression_duration_threshold = 10  # % change threshold, changes below this are neutral
      @regression_memory_threshold = 10    # % change threshold
      @regression_query_threshold = 0      # % change threshold, 0 means any query count increase is a regression
      @regression_cache_threshold = 5      # % change threshold for cache hit rate
    end

    attr_reader :collector_circuit_breaker_threshold

    # A positive Integer. Anything else is left out with a warning, the previous value kept: the
    # gem is loaded in production too, where a mistake here must not stop the application booting.
    def collector_circuit_breaker_threshold=(value)
      if value.is_a?(Integer) && value.positive?
        @collector_circuit_breaker_threshold = value
      else
        Profiler.log_warn("config.collector_circuit_breaker_threshold: #{value.inspect} is not a positive " \
                          "Integer; keeping #{@collector_circuit_breaker_threshold}")
      end
    end

    # The editor the file:line links open: "vscode", "idea" or "cursor" (String or Symbol). A
    # value outside that list is kept as given, but #editor_link_scheme answers nil for it, so
    # that no link is built.
    # Nil or empty turns the webhook off. Otherwise an absolute http(s) URL with a host, and no
    # user or password in it: the webhook sends none, so a URL carrying them is refused rather than
    # silently called without them.
    def alert_webhook_url=(value)
      @alert_webhook_url = Alerts::Webhook.validate!(value)
    end

    def editor_url_scheme=(value)
      @editor_url_scheme = value.nil? ? nil : value.to_s
    end

    # Container path prefix => host path prefix, for a server running in a container while the
    # editor runs on the host: { "/app" => "/home/me/project" }. The longest matching prefix wins.
    def editor_path_map=(value)
      unless value.nil? || value.respond_to?(:to_h)
        raise ArgumentError, "editor_path_map must be a Hash of container path => host path"
      end

      @editor_path_map = (value || {}).to_h.to_h { |from, to| [from.to_s, to.to_s] }
    end

    # The scheme the dashboard may use, or nil when the setting is not on the allow list.
    def editor_link_scheme
      EDITOR_URL_SCHEMES.include?(@editor_url_scheme) ? @editor_url_scheme : nil
    end

    # Always a Pathname, whether set from a String or left to its default.
    def tmp_path
      @tmp_path || default_tmp_path
    end

    def tmp_path=(value)
      @tmp_path = value.nil? ? nil : Pathname.new(value)
    end

    attr_reader :cluster_allowed_slave_urls, :mcp_allowed_hosts, :skip_paths, :http_skip_hosts

    # Paths that are not profiled: a Regexp matched against the path, or a String equal to it.
    # A single pattern is a list of one.
    def skip_paths=(value)
      @skip_paths = Array(value)
    end

    # Hosts whose outbound calls are left out: a String is a host name, matched whole and
    # case-insensitively, or, when it starts with a dot (".internal"), a domain whose subdomains
    # are left out; a Regexp is matched against the host name. Any other entry (a wildcard
    # "*.internal", an empty String, nil) is left out with a warning in the log, the others kept:
    # the gem is loaded in production too, where a mistake here must not stop the application
    # from booting.
    def http_skip_hosts=(value)
      @http_skip_hosts = Array(value).select { |entry| valid_http_skip_host?(entry) }
    end

    # Host names the MCP HTTP endpoint accepts beyond the loopback ones and config.hosts: a String
    # (a host name, any port, or a host:port) or a Regexp anchored with \A and \z, matched
    # against the host name without its port. A wildcard String is refused.
    def mcp_allowed_hosts=(value)
      require_relative "cluster/security"
      Array(value).each { |entry| validate_mcp_allowed_host(entry) }
      @mcp_allowed_hosts = Array(value)
    end

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

    # The service.name of the exported spans: otel_service_name, else the application's name.
    def resolved_otel_service_name
      otel_service_name.to_s.strip.empty? ? resolved_name : otel_service_name.to_s
    end

    def resolved_name
      @name || (defined?(Rails) ? Rails.application.class.module_parent_name.underscore : "profiler")
    end

    # Block called with the alert (a Hash, see Profiler::Alerts) each time a profile crosses a
    # threshold or shows an N+1. Only runs when config.alerts_enabled is true.
    def on_detection(&block)
      @on_detection = block if block
      @on_detection
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
        run_authorize_block(request)
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

    def validate_mcp_allowed_host(entry)
      case entry
      when String
        return unless entry.strip.empty? || entry.include?("*")

        raise ArgumentError, "config.mcp_allowed_hosts: #{entry.inspect} is not a host name; list each host, " \
                             "or use an anchored Regexp"
      when Regexp then validate_mcp_allowed_host_pattern(entry)
      else raise ArgumentError, "config.mcp_allowed_hosts: #{entry.inspect} must be a String or a Regexp"
      end
    end

    def valid_http_skip_host?(entry)
      problem =
        case entry
        when Regexp then nil
        when String
          if entry.strip.empty? || entry.match?(/[*\s]/)
            "is not a host name; list each host, a domain as \".internal\" for its subdomains, or use a Regexp"
          end
        else "must be a String or a Regexp"
        end
      return true unless problem

      Profiler.log_warn("config.http_skip_hosts: #{entry.inspect} #{problem}; ignored")
      false
    end

    def validate_mcp_allowed_host_pattern(pattern)
      unless Profiler::Cluster::Security.anchored_pattern?(pattern)
        raise ArgumentError, "config.mcp_allowed_hosts: #{pattern.inspect} must start with \\A and end with \\z, " \
                             "so that it matches the whole host name"
      end
      Profiler::Cluster::Security.whole_url_pattern(pattern)
    rescue RegexpError => e
      raise ArgumentError, "config.mcp_allowed_hosts: #{pattern.inspect} cannot be matched against the whole " \
                           "host name (#{e.message})"
    end

    # An exception in the application's own authorization code is a denial, never an error
    # for the request: it would otherwise break every request. The detail stays in the log.
    def run_authorize_block(request)
      return false unless @authorize_block

      @authorize_block.call(request) ? true : false
    rescue StandardError => e
      Profiler.log_error("authorize_with block raised, treating the request as unauthorized", e)
      false
    end
  end
end
