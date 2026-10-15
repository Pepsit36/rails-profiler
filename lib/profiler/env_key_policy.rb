# frozen_string_literal: true

module Profiler
  # Which environment variables the profiler may change: the Env tab, the MCP env tools, the
  # overrides replayed by EnvOverrideStore#apply! and the environment of the test runner all
  # read this one list.
  #
  # It is a deny list, chosen over an allow list on purpose (DECISIONS.md): the Env tab exists for
  # the application's own variables, feature flags and API URLs, whose names nobody can enumerate
  # in the gem. A deny list is by nature incomplete: any gem, library or tool the application uses
  # can read a variable of its own tomorrow, a new database adapter or HTTP client among them, and
  # no list written here can foresee it. The names below are the ones known to redirect the
  # application's connections, hand over its secrets, or make a process load other code; a
  # variable left out here can still be set in the shell that starts the application.
  module EnvKeyPolicy
    # Set by the test runner in the environment of the test process.
    TEST_RUNNER_CHILD_ENV = "PROFILER_TEST_RUNNER_CHILD"
    RESERVED_KEY_ERROR = "#{TEST_RUNNER_CHILD_ENV} is reserved for the test runner"

    # Select the environment, the database or the secrets of the application, where it connects
    # and which certificates it trusts, or the profiler's own read-only switch.
    PROTECTED_KEYS = %w[
      RAILS_ENV RACK_ENV DATABASE_URL SECRET_KEY_BASE RAILS_MASTER_KEY PROFILER_TEST_RUNNER_CHILD
      PROFILER_MCP_READ_ONLY SSL_CERT_FILE SSL_CERT_DIR
    ].freeze
    # PG: libpq (PGHOST, PGPASSWORD, PGSERVICEFILE...). MYSQL_: the MySQL client (MYSQL_PWD,
    # MYSQL_HOST...). OPENSSL_: OPENSSL_CONF and OPENSSL_MODULES can load a shared library.
    PROTECTED_PREFIXES = %w[PG MYSQL_ OPENSSL_].freeze
    # _DATABASE_URL: ActiveRecord reads PRIMARY_DATABASE_URL (any <name>_DATABASE_URL of a
    # multi-database configuration) before DATABASE_URL. _PROXY: http_proxy, HTTPS_PROXY, no_proxy
    # and the others, read again by Net::HTTP at each connection, whatever their case.
    PROTECTED_SUFFIXES = %w[_DATABASE_URL _PROXY].freeze

    # Overrides of these variables make a process, or the shell shims (rbenv, asdf) that start
    # it, load or run code other than its own.
    CODE_LOADING_KEYS = %w[
      SPEC_OPTS TESTOPTS TEST PATH HOME XDG_CONFIG_HOME GEMRC NODE_OPTIONS NODE_PATH
      SHELLOPTS BASHOPTS PS4 ENV CDPATH IFS ZDOTDIR GCONV_PATH LOCPATH IRBRC PRYRC PRY_RC
      LESSOPEN LESSCLOSE PAGER EDITOR VISUAL JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS
    ].freeze
    CODE_LOADING_PREFIXES = %w[
      RUBY GEM_ BUNDLE_ BUNDLER_ LD_ DYLD_ BASH_ RBENV_ ASDF_ RVM_ CHRUBY GIT_ BOOTSNAP_
      PYTHON PERL5
    ].freeze

    # Letters, digits and underscores, not starting with a digit. Anything else, "=" or a NUL
    # byte above all, either cannot be written into ENV or is not a name a shell can set.
    ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/i

    module_function

    def valid_name?(key)
      ENV_NAME.match?(key.to_s)
    end

    def reserved?(key)
      key.to_s.upcase == TEST_RUNNER_CHILD_ENV
    end

    def protected?(key)
      name = key.to_s.upcase
      PROTECTED_KEYS.include?(name) ||
        PROTECTED_PREFIXES.any? { |prefix| name.start_with?(prefix) } ||
        PROTECTED_SUFFIXES.any? { |suffix| name.end_with?(suffix) }
    end

    # True for a name that is not valid, too: the test runner leaves those out with the others.
    def code_loading?(key)
      name = key.to_s.upcase
      return true unless valid_name?(name)

      CODE_LOADING_KEYS.include?(name) || CODE_LOADING_PREFIXES.any? { |prefix| name.start_with?(prefix) }
    end

    # Why the profiler refuses to set or delete key, or nil when it may.
    def rejection(key)
      name = key.to_s
      return "key cannot be blank" if name.strip.empty?
      return RESERVED_KEY_ERROR if reserved?(name)
      unless valid_name?(name)
        return "#{name.inspect} is not a valid environment variable name " \
               "(letters, digits and underscores, not starting with a digit)"
      end
      if protected?(name) || code_loading?(name)
        return "#{name} is protected: the profiler does not change the variables that select the " \
               "environment, the database, the secrets or the network of the application, nor " \
               "those that make a process load other code"
      end

      nil
    end

    # Why the profiler refuses to set key to value, or nil when it may. A NUL byte cannot be held
    # by an environment variable: ENV[]= raises on it.
    def value_rejection(key, value)
      return nil unless value.to_s.include?("\0")

      "the value of #{key} contains a NUL byte, which an environment variable cannot hold"
    end

    def allowed?(key)
      rejection(key).nil?
    end
  end
end
