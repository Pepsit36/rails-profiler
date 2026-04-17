# frozen_string_literal: true

require_relative "run_store"
require_relative "discovery"

module Profiler
  module TestRunner
    class Runner
      def self.start(files:, framework:)
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
        end
      end

      def self.run_process(run)
        cmd = build_command(run.files, run.framework)
        env = build_env

        Profiler::TestRunner.run_store.update(run.id, status: "running", started_at: Time.now)

        IO.popen([env, *cmd, err: [:child, :out]], "r") do |io|
          Profiler::TestRunner.run_store.update(run.id, pid: io.pid)

          while (chunk = io.read(256))
            break if chunk.empty?

            Profiler::TestRunner.run_store.append_output(run.id, chunk)
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
        root = defined?(Rails) ? Rails.root.to_s : Dir.pwd
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

      def self.build_env
        base = ENV.to_h

        # Inject env var overrides configured in the profiler
        overrides = Profiler.env_override_store.all_overrides
        overrides.each do |key, entry|
          value = entry.is_a?(Hash) ? entry["value"] : entry
          base[key] = value
        end

        # Ensure test environment
        base["RAILS_ENV"] ||= "test"
        base["RACK_ENV"]  ||= "test"

        base
      end
    end
  end
end
