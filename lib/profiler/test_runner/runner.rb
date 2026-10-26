# frozen_string_literal: true

require "set"
require_relative "../boot_env"
require_relative "../env_override_store"
require_relative "../env_key_policy"
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
      # Raises TooManyRunsError when config.test_runner_max_active_runs runs still have their
      # test process.
      def self.start(files:, framework:)
        unless framework.is_a?(String) || framework.is_a?(Symbol)
          raise ArgumentError, "framework must be a String or Symbol"
        end

        framework = framework.to_s

        validate_files!(files, framework)
        config = Profiler.configuration
        run = Profiler::TestRunner.run_store.create(
          files: files, framework: framework,
          max_active: config.test_runner_max_active_runs,
          max_output_bytes: config.test_runner_max_output_bytes
        )
        spawn_async(run)
        run
      end

      # The test process leads its own process group (see run_process): TERM goes to the whole
      # group, the processes rspec or rails started included, and KILL follows after
      # config.test_runner_kill_grace_seconds for whatever is still there.
      def self.kill(run_id)
        run = Profiler::TestRunner.run_store.find(run_id)
        return false unless run && run.pid && run.status == "running"

        begin
          Process.kill("TERM", -run.pid)
        rescue Errno::ESRCH
          # Process already exited
          return false
        end
        Profiler::TestRunner.run_store.update(run_id, status: "killed", finished_at: Time.now)
        kill_group_later(run.pid)
        true
      end

      # The group exists as long as one of its processes does. Its id is the pid of the test
      # process, which the system can give to a new process once the whole group is gone; that
      # takes the pids to wrap around within the delay, and the new process would have to lead a
      # group of its own.
      def self.kill_group_later(pgid)
        delay = Profiler.configuration.test_runner_kill_grace_seconds.to_f
        Thread.new do
          sleep delay
          Process.kill("KILL", -pgid)
        rescue Errno::ESRCH, Errno::EPERM
          nil # the group ended on TERM
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
                              "config.test_runner_allow_undiscovered_files is enabled: the test runner " \
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

        Profiler.log_warn(message)
      end

      def self.reset_warnings!
        @warn_mutex.synchronize { @warned = {} }
      end

      private

      def self.spawn_async(run)
        Thread.new do
          run_process(run)
        rescue => e
          # The output first: a page following the run stops at its terminal status.
          Profiler::TestRunner.run_store.append_output(run.id, "\n[Profiler] Error: #{e.message}\n")
          Profiler::TestRunner.run_store.finish_output(run.id)
          Profiler::TestRunner.run_store.update(
            run.id,
            status: "error",
            finished_at: Time.now
          )
        ensure
          Profiler::TestRunner.run_store.release(run.id)
        end
      end

      def self.run_process(run)
        cmd = build_command(run.files, run.framework)
        env = build_env

        Profiler::TestRunner.run_store.update(run.id, status: "running", started_at: Time.now)

        # unsetenv_others: the child gets exactly env, not the ENV of this process. pgroup: the
        # child leads a process group of its own, which kill stops as a whole.
        IO.popen([env, *cmd, unsetenv_others: true, pgroup: true, err: [:child, :out]], "r") do |io|
          Profiler::TestRunner.run_store.update(run.id, pid: io.pid)

          begin
            while (chunk = io.readpartial(4096))
              Profiler::TestRunner.run_store.append_output(run.id, chunk)
            end
          rescue EOFError
            # End of stream reached
          ensure
            # The process printed everything, killed or not: what was held back can be shown.
            Profiler::TestRunner.run_store.finish_output(run.id)
          end
        end

        process_status = $?
        exit_code = process_status.exitstatus # nil when a signal ended the process
        signal = signal_name(process_status.termsig) if process_status.signaled?
        # A run killed from the profiler stays killed, whatever the process answered to TERM.
        status = if run.status == "killed" then "killed"
                 elsif signal then "signaled"
                 elsif exit_code == 0 then "passed"
                 else "failed"
                 end

        if status == "signaled"
          # Before the status: a page following the run stops at its terminal status.
          Profiler::TestRunner.run_store.append_output(
            run.id, "\n[Profiler] The test process was ended by #{signal} before it finished: " \
                    "the result of the tests is unknown.\n"
          )
        end

        Profiler::TestRunner.run_store.update(
          run.id,
          status: status,
          finished_at: Time.now,
          exit_code: exit_code,
          signal: signal
        )
      end

      def self.signal_name(number)
        name = Signal.signame(number)
        name ? "SIG#{name}" : "signal #{number}"
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

      # The lists live in Profiler::EnvKeyPolicy, shared with the Env tab and the MCP env tools.
      BLOCKED_ENV_KEYS = EnvKeyPolicy::PROTECTED_KEYS
      CODE_LOADING_ENV_KEYS = EnvKeyPolicy::CODE_LOADING_KEYS
      CODE_LOADING_ENV_PREFIXES = EnvKeyPolicy::CODE_LOADING_PREFIXES
      ENV_NAME = EnvKeyPolicy::ENV_NAME

      def self.code_loading_env_key?(key)
        EnvKeyPolicy.code_loading?(key)
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
          blocked = EnvKeyPolicy.protected?(key)
          if blocked || code_loading_env_key?(key)
            left_out << key unless blocked
            next
          end
          value = entry.is_a?(Hash) ? entry["value"] : entry
          # A value the process environment cannot hold, saved by a version that did not check it.
          next if EnvKeyPolicy.value_rejection(key, value)

          if value == EnvOverrideStore::DELETED_SENTINEL
            base.delete(key)
          else
            base[key] = value
          end
        end

        unless left_out.empty?
          warn_once([:env, left_out.sort],
                    "Environment overrides not passed to the test runner, because they make it " \
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
