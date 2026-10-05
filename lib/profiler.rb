# frozen_string_literal: true

# First, so that the copy of ENV is taken before anything writes into it
require_relative "profiler/boot_env"
require_relative "profiler/version"
require_relative "profiler/configuration"
require_relative "profiler/redaction"
require_relative "profiler/allocation_counter"

module Profiler
  class Error < StandardError; end

  # The longest error message, in bytes, a log line carries: a parser error can quote what it
  # was parsing.
  LOG_ERROR_MESSAGE_LIMIT = 1000

  class << self
    attr_writer :configuration
    attr_accessor :function_profiling_enabled
    attr_accessor :function_profiling_max_frames
    attr_accessor :function_profiling_mode
    attr_accessor :function_profiling_clock
    # Without stackprof, the function profiler stays off unless this is true: it then traces
    # every method call of the request's thread with a TracePoint, several times slower.
    attr_accessor :function_profiling_tracepoint_fallback

    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    STORAGE_LOCK = Mutex.new

    # Built once, under a lock: the first requests of a threaded server ask for it together, and
    # a profile saved into a store that another thread replaced would be lost. Read without the
    # lock once it exists.
    # A store that cannot be created is said once (Storage::Unavailable) and tried again on the
    # next call.
    def storage
      @storage || STORAGE_LOCK.synchronize { @storage ||= configuration.storage_backend }
    rescue StandardError => e
      Storage::Unavailable.for(e)
    end

    # Saves a profile from a path of the application (a job, a console command, a test, an
    # outbound HTTP call): a storage error loses the profile, never the application's work.
    # True when saved; false when the error was logged instead, or when the store is unavailable
    # (Storage::Unavailable drops the save, and has said why once already).
    def save_profile(profile, from:)
      target = storage
      return false if target.is_a?(Storage::Unavailable)

      target.save(profile.token, profile)
      true
    rescue StandardError => e
      log_error("#{from}: could not save profile #{profile.token}", e)
      false
    end

    # The profiler's own messages, to config.logger when the application sets one (read on each
    # message), else to +logger+ when given (Rails.logger at boot), else to Rails.logger, else to
    # $stderr.
    # Prefixed [Profiler], with the profiler's credentials masked. Never raises: a logger that
    # fails sends the line to $stderr instead. While the line is written, the thread is marked
    # (Thread.current[:profiler_logging]) so that the Logs tab of a profile being recorded does
    # not take it for one of the application's lines.
    def log(level, message, error = nil, backtrace: false, logger: nil)
      line = log_line(message, error, backtrace)
      logger = configured_logger || logger || current_logger
      if logger
        begin
          return write_log(logger, level, line)
        rescue StandardError
          # Below, to $stderr: the message is not lost.
        end
      end
      $stderr.write("#{line}\n")
      nil
    rescue StandardError
      nil
    end

    def log_error(message, error = nil, backtrace: false)
      log(:error, message, error, backtrace: backtrace)
    end

    def log_warn(message, error = nil, logger: nil)
      log(:warn, message, error, logger: logger)
    end

    def log_info(message)
      log(:info, message)
    end

    # Like log_error, once per +site+ and error class: for the paths called again and again (a
    # store read on every poll), where the same failure would otherwise fill the log.
    def log_error_once(site, message, error)
      key = [site, error.class]
      @logged_once_mutex.synchronize do
        return nil if @logged_once.include?(key)

        @logged_once << key
      end
      log_error(message, error)
    end

    # Runs the block without recording its outgoing HTTP calls in the current profile: the
    # profiler's own calls (the cluster's registration and heartbeats, the master's requests to
    # its slaves) are not the application's.
    def untracked_http
      previous = Thread.current[:profiler_http_untracked]
      Thread.current[:profiler_http_untracked] = true
      yield
    ensure
      Thread.current[:profiler_http_untracked] = previous
    end

    def env_override_store
      @env_override_store ||= EnvOverrideStore.new
    end

    def slave_registry
      @slave_registry ||= begin
        require_relative "profiler/cluster/slave_registry"
        Cluster::SlaveRegistry.new
      end
    end

    def token_cache
      @token_cache ||= begin
        require_relative "profiler/cluster/token_cache"
        Cluster::TokenCache.new
      end
    end

    def enabled?
      configuration.enabled
    end

    # Instrument an arbitrary code block and record it in the FlameGraph.
    # Usage: Profiler.measure("payment.stripe_charge", metadata: { amount: 1000 }) { Stripe::Charge.create(...) }
    def measure(label, metadata: {}, &block)
      return yield unless enabled?

      collector = Thread.current[:profiler_flamegraph_collector]
      return yield unless collector

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      finished_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      collector.record_custom_event(
        label: label,
        started_at: started_at,
        finished_at: finished_at,
        metadata: metadata
      )

      result
    end

    private

    def configured_logger
      configuration.logger
    rescue StandardError
      nil
    end

    def current_logger
      configured = configuration.logger
      return configured if configured
      return nil unless defined?(::Rails) && ::Rails.respond_to?(:logger)

      ::Rails.logger
    rescue StandardError
      nil
    end

    def write_log(logger, level, line)
      previous = Thread.current[:profiler_logging]
      Thread.current[:profiler_logging] = true
      logger.public_send(level, line)
    ensure
      Thread.current[:profiler_logging] = previous
    end

    # Masked whole, then cut: a cut first could leave the start of a credential, which the
    # masking by value would no longer find.
    def log_line(message, error, backtrace)
      line = +"[Profiler] #{message}"
      if error
        line << ": #{error.class}"
        text = error_text(error)
        line << ": #{text}" unless text.empty?
        line << "\n#{error.backtrace.join("\n")}" if backtrace && error.backtrace
      end
      Redaction.hide_credentials(line)
    end

    # The error's message, masked, then cut at LOG_ERROR_MESSAGE_LIMIT bytes. A message that
    # raises leaves the class alone.
    def error_text(error)
      text = Redaction.hide_credentials(error.message.to_s)
      return text if text.bytesize <= LOG_ERROR_MESSAGE_LIMIT

      "#{Redaction.cut_bytes(text, LOG_ERROR_MESSAGE_LIMIT).scrub("")}..."
    rescue StandardError
      ""
    end

    public

    # Dump a variable to the profiler
    # Usage: Profiler.dump(variable, "optional label")
    def dump(value, label = nil)
      return value unless enabled?

      # The slot exists only while a DumpCollector profiles this thread: outside of one, nobody
      # would ever read the dump, and the thread would keep it for good.
      dumps = Thread.current[:profiler_dumps]
      return value unless dumps

      # Get caller location
      caller_location = caller_locations(1, 1).first
      file = caller_location.path
      line = caller_location.lineno

      # Store the dump
      dumps << {
        value: value,
        label: label,
        file: file,
        line: line,
        timestamp: Time.now
      }

      value
    end
  end

  @logged_once = Set.new
  @logged_once_mutex = Mutex.new

  self.function_profiling_enabled = true
  self.function_profiling_max_frames = 2000
  self.function_profiling_mode = "lite"
  self.function_profiling_clock = "wall"
  self.function_profiling_tracepoint_fallback = false
end

# Require core components
require_relative "profiler/collectors/base_collector"
require_relative "profiler/collectors/request_collector"
require_relative "profiler/collectors/database_collector"
require_relative "profiler/collectors/ajax_collector"
require_relative "profiler/collectors/view_collector"
require_relative "profiler/collectors/cache_collector"
require_relative "profiler/collectors/dump_collector"
require_relative "profiler/collectors/http_collector"
require_relative "profiler/collectors/flamegraph_collector"
require_relative "profiler/collectors/function_profiler_collector"
require_relative "profiler/collectors/log_collector"
require_relative "profiler/collectors/exception_collector"
require_relative "profiler/collectors/routes_collector"
require_relative "profiler/collectors/i18n_collector"
require_relative "profiler/collectors/env_collector"
require_relative "profiler/collectors/mailer_collector"

require_relative "profiler/storage/token"
require_relative "profiler/storage/private_files"
require_relative "profiler/storage/unavailable"
require_relative "profiler/ajax_data"
require_relative "profiler/env_override_store"
require_relative "profiler/instrumentation/thread_context_propagation"
require_relative "profiler/instrumentation/executor_context_propagation"
require_relative "profiler/sse/event_bus"
require_relative "profiler/sse/redis_event_bus"
require_relative "profiler/sse/bus"
require_relative "profiler/railtie" if defined?(Rails::Railtie)
require_relative "profiler/engine" if defined?(Rails::Engine)
