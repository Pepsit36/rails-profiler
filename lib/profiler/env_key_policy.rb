# frozen_string_literal: true

module Profiler
  # Which environment variables the profiler may change: the Env tab, the MCP env tools, the
  # overrides replayed by EnvOverrideStore#apply! and the environment of the test runner all
  # read this one list. It is a deny list, so it cannot be complete; a variable left out here
  # can still be set in the shell that starts the application.
  module EnvKeyPolicy
    # Set by the test runner in the environment of the test process.
    TEST_RUNNER_CHILD_ENV = "PROFILER_TEST_RUNNER_CHILD"
    RESERVED_KEY_ERROR = "#{TEST_RUNNER_CHILD_ENV} is reserved for the test runner"

    # Select the environment, the database or the secrets of the application.
    PROTECTED_KEYS = %w[RAILS_ENV RACK_ENV DATABASE_URL SECRET_KEY_BASE PROFILER_TEST_RUNNER_CHILD].freeze

    # Overrides of these variables make a process, or the shell shims (rbenv, asdf) that start
    # it, load or run code other than its own.
    CODE_LOADING_KEYS = %w[
      SPEC_OPTS TESTOPTS TEST PATH HOME XDG_CONFIG_HOME GEMRC NODE_OPTIONS NODE_PATH
      SHELLOPTS BASHOPTS PS4 ENV CDPATH IFS
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
      PROTECTED_KEYS.include?(key.to_s.upcase)
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
               "environment, the database or the secrets, nor those that make a process load other code"
      end

      nil
    end

    def allowed?(key)
      rejection(key).nil?
    end
  end
end
