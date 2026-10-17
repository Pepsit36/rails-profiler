# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "security"

module Profiler
  module Cluster
    class MasterClient
      # Process._fork (Ruby 3.1+) runs in the parent and in the child alike. A thread does not
      # survive a fork, so a worker forked from a process that had started the client (Puma in
      # cluster mode with preload_app!, a preloaded Unicorn) would never heartbeat.
      module ForkHook
        def _fork
          pid = super
          MasterClient.restart_after_fork if pid.zero?
          pid
        end
      end

      class << self
        # The client the railtie started in this process, for the fork hook to restart.
        attr_accessor :current

        def install_fork_hook!
          return false if @fork_hook_installed || !Process.respond_to?(:_fork)

          Process.singleton_class.prepend(ForkHook)
          @fork_hook_installed = true
        end

        def restart_after_fork
          current&.restart_after_fork
        rescue => e
          Profiler.log_warn("Cluster: could not restart the heartbeat after a fork", e)
        end
      end

      def start
        self.class.current = self
        self.class.install_fork_hook!
        @registered = false
        begin
          register!
          @registered = true
        rescue => e
          log_warn("could not register with master at startup, will retry in the heartbeat loop", e)
        end
        @started = true
        start_heartbeat_thread
      end

      # In the child of a fork: the heartbeat thread of the parent is gone and the parent's
      # registration is not the child's own, so register again from the new thread.
      # Does nothing while a heartbeat thread is alive, nor before start.
      def restart_after_fork
        return if @started.nil? || @thread&.alive?

        @registered = false
        start_heartbeat_thread
      end

      private

      def register!
        config = Profiler.configuration
        uri = master_uri("register")
        body = { name: config.resolved_name, url: config.self_url }.to_json
        resp = Profiler.untracked_http { Net::HTTP.post(uri, body, request_headers) }
        unless resp.code.to_i.between?(200, 299)
          raise "Master returned #{resp.code}: #{resp.body.to_s.slice(0, 200)}"
        end

        log_info("Registered with master at #{config.master_url} as '#{config.resolved_name}'")
      end

      def heartbeat!
        config = Profiler.configuration
        uri = master_uri("heartbeat")
        body = { name: config.resolved_name }.to_json
        resp = Profiler.untracked_http { Net::HTTP.post(uri, body, request_headers) }
        raise "Heartbeat rejected #{resp.code}" unless resp.code.to_i.between?(200, 299)
      end

      # Refused before any request when the secret would cross the network in clear, or when
      # there is no secret for the master to accept.
      def master_uri(action)
        config = Profiler.configuration
        if (reason = Security.master_url_denial(config.master_url))
          raise reason
        end
        if Security.secret_required? && (problem = Security.secret_problem)
          raise "#{problem}: the master refuses registration without a secret"
        end

        URI("#{config.master_url}/_profiler/api/cluster/#{action}")
      end

      def request_headers
        { "Content-Type" => "application/json", Profiler::FORGERY_PROTECTION_HEADER => "1" }
          .merge(Security.outgoing_headers)
      end

      def start_heartbeat_thread
        return if @thread&.alive?

        @thread = Thread.new do
          interval = Profiler.configuration.cluster_heartbeat_interval
          loop do
            sleep interval
            unless @registered
              register!
              @registered = true
              log_info("Re-registered with master after previous failure")
            else
              heartbeat!
            end
          rescue => e
            @registered = false
            log_warn("communication with the master failed, will retry", e)
          end
        end
      end

      def log_info(msg)
        Profiler.log_info("Cluster: #{msg}")
      end

      def log_warn(msg, error = nil)
        Profiler.log_warn("Cluster: #{msg}", error)
      end
    end
  end
end
