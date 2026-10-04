# frozen_string_literal: true

require "set"
require_relative "../boot_env"
require_relative "../env_override_store"
require_relative "run_store"
require_relative "discovery"

module Profiler
  module TestRunner
    # Raised by Runner.start when the selection holds a file that is not a discovered test.
    class InvalidFileError < ArgumentError; end

    class Runner
      # "spec/models/user_spec.rb:12" or ":12:30": the line selection rspec and minitest accept.
      LINE_SUFFIX = /\A(.+?)((?::\d+)+)\z/

      @warn_mutex = Mutex.new
      @warned = {}

      # Every caller (the HTTP controller, the MCP run_tests tool) goes through here, so the
      # selection is checked once, before any run is recorded or any process is started.
      def self.start(files:, framework:)
        validate_files!(files, framework)
        run = Profiler::TestRunner.run_store.create(files: files, framework: framework)
        spawn_async(run)
        run
      end

      def self.kill(run_id)
        run = Profiler::TestRunner.run_store.find(run_id)
        return false unless run && run.pid && run.status == "running"

        begin
          Process.kill("TERM", run.pid)
          Profiler::TestRunner.run_store.update(run_id, status: "killed", finished_at: Time.now)
          true
        rescue Errno::ESRCH
          # Process already exited
          false
        end
      end

      # Accepts only files listed by Discovery.files for the framework, compared by their
      # canonical path (File.realpath, symbolic links resolved), so that a test run cannot be
      # used to execute any other Ruby file of the application.
      def self.validate_files!(files, framework)
        files = Array(files)
        raise InvalidFileError, "No files selected" if files.empty?

        root = project_root
        allowed = if Profiler.configuration.test_runner_allow_undiscovered_files
                    warn_once(:undiscovered,
                              "[Profiler] config.test_runner_allow_undiscovered_files is enabled: the test runner " \
                              "runs any file under the Rails root, not only the discovered tests.")
                    nil
                  else
                    discovered_real_paths(root, framework)
                  end

        refused = files.reject do |entry|
          next false unless entry.is_a?(String) && !entry.empty? && !entry.include?("\0")

          path = entry[LINE_SUFFIX, 1] || entry
          allowed ? allowed.include?(real_path(File.join(root, path))) : under_root?(root, File.join(root, path))
        end
        return if refused.empty?

        message = allowed ? "Not a discovered test file" : "Not a file under the Rails root"
        raise InvalidFileError, "#{message}: #{refused.map(&:to_s).join(", ")}"
      end

      def self.discovered_real_paths(root, framework)
        real_root = real_path(root)
        Discovery.files(framework: framework).flat_map { |dir| dir[:files] }.filter_map do |file|
          path = real_path(File.join(root, file[:path]))
          # A discovered symbolic link whose target leaves the project is not a project test.
          path if path && real_root && path.start_with?("#{real_root}/")
        end.to_set
      end

      def self.real_path(path)
        File.realpath(path)
      rescue SystemCallError, ArgumentError
        nil
      end

      def self.under_root?(root, path)
        expanded = File.expand_path(path)
        expanded == root || expanded.start_with?("#{root}/")
      end

      def self.project_root
        defined?(Rails) ? Rails.root.to_s : Dir.pwd
      end

      def self.warn_once(key, message)
        @warn_mutex.synchronize do
          return if @warned[key]

          @warned[key] = true
        end

        if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
          Rails.logger.warn(message)
        else
          warn(message)
        end
      end

      def self.reset_warnings!
        @warn_mutex.synchronize { @warned = {} }
      end

      private

      def self.spawn_async(run)
        Thread.new do
          run_process(run)
        rescue => e
          Profiler::TestRunner.run_store.update(
            run.id,
            status: "error",
            finished_at: Time.now
          )
          Profiler::TestRunner.run_store.append_output(run.id, "\n[Profiler] Error: #{e.message}\n")
          Profiler::TestRunner.run_store.finish_output(run.id)
        end
      end

      def self.run_process(run)
        cmd = build_command(run.files, run.framework)
        env = build_env

        Profiler::TestRunner.run_store.update(run.id, status: "running", started_at: Time.now)

        # unsetenv_others: the child gets exactly env, not the ENV of this process
        IO.popen([env, *cmd, unsetenv_others: true, err: [:child, :out]], "r") do |io|
          Profiler::TestRunner.run_store.update(run.id, pid: io.pid)

          begin
            while (chunk = io.read(256))
              break if chunk.empty?

              Profiler::TestRunner.run_store.append_output(run.id, chunk)
            end
          ensure
            # The process printed everything, killed or not: what was held back can be shown.
            Profiler::TestRunner.run_store.finish_output(run.id)
          end
        end

        exit_code = $?.exitstatus || 0
        status = exit_code == 0 ? "passed" : "failed"

        Profiler::TestRunner.run_store.update(
          run.id,
          status: status,
          finished_at: Time.now,
          exit_code: exit_code
        )
      end

      def self.build_command(files, framework)
        root = project_root
        absolute_files = files.map { |f| File.join(root, f) }

        case framework.to_sym
        when :rspec
          ["bundle", "exec", "rspec", "--format", "progress", "--color", *absolute_files]
        when :minitest
          ["bundle", "exec", "rails", "test", *absolute_files]
        else
          ["bundle", "exec", "rspec", "--format", "progress", "--color", *absolute_files]
        end
      end

      BLOCKED_ENV_KEYS = %w[RAILS_ENV RACK_ENV DATABASE_URL SECRET_KEY_BASE PROFILER_TEST_RUNNER_CHILD].freeze

      # Overrides of these variables make the test process, or the shell shims (rbenv, asdf) that
      # start it, load or run code other than the selected tests. It is a deny list, so it cannot
      # be complete; a variable needed by the tests can be set in the shell that starts Rails.
      CODE_LOADING_ENV_KEYS = %w[
        SPEC_OPTS TESTOPTS TEST PATH HOME XDG_CONFIG_HOME GEMRC NODE_OPTIONS NODE_PATH
        SHELLOPTS BASHOPTS PS4 ENV CDPATH IFS
      ].freeze
      CODE_LOADING_ENV_PREFIXES = %w[
        RUBY GEM_ BUNDLE_ BUNDLER_ LD_ DYLD_ BASH_ RBENV_ ASDF_ RVM_ CHRUBY GIT_ BOOTSNAP_
        PYTHON PERL5
      ].freeze
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/i

      def self.code_loading_env_key?(key)
        name = key.to_s.upcase
        return true unless ENV_NAME.match?(name)

        CODE_LOADING_ENV_KEYS.include?(name) || CODE_LOADING_ENV_PREFIXES.any? { |prefix| name.start_with?(prefix) }
      end

      # Starts from the copy of ENV taken when the gem was loaded, not from ENV: the overrides are
      # also written into ENV (by the env vars endpoint, the MCP tools and EnvOverrideStore#apply!),
      # and one whose entry the store lost would pass unnoticed. Only the overrides read from the
      # store and admitted are applied on top; a left-out or blocked key keeps its shell value.
      def self.build_env
        base = Profiler::BOOT_ENV.dup
        left_out = []

        overrides = Profiler.env_override_store.all_overrides
        overrides.each do |key, entry|
          blocked = BLOCKED_ENV_KEYS.include?(key.upcase)
          if blocked || code_loading_env_key?(key)
            left_out << key unless blocked
            next
          end
          value = entry.is_a?(Hash) ? entry["value"] : entry
          if value == EnvOverrideStore::DELETED_SENTINEL
            base.delete(key)
          else
            base[key] = value
          end
        end

        unless left_out.empty?
          warn_once([:env, left_out.sort],
                    "[Profiler] Environment overrides not passed to the test runner, because they make it " \
                    "load other code: #{left_out.sort.join(", ")}.")
        end

        # Ensure test environment regardless of overrides
        base["RAILS_ENV"] = "test"
        base["RACK_ENV"]  = "test"
        # The test process boots the same application: its EnvOverrideStore#apply! must not
        # replay the overrides left out above
        base[EnvOverrideStore::TEST_RUNNER_CHILD_ENV] = "1"

        base
      end
    end
  end
end
