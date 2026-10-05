# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "security"

module Profiler
  module Cluster
    class MasterClient
      def start
        @registered = false
        begin
          register!
          @registered = true
        rescue => e
          log_warn("could not register with master at startup, will retry in the heartbeat loop", e)
        end
        start_heartbeat_thread
      end

      private

      def register!
        config = Profiler.configuration
        uri = master_uri("register")
        body = { name: config.resolved_name, url: config.self_url }.to_json
        resp = Net::HTTP.post(uri, body, request_headers)
        unless resp.code.to_i.between?(200, 299)
          raise "Master returned #{resp.code}: #{resp.body.to_s.slice(0, 200)}"
        end

        log_info("Registered with master at #{config.master_url} as '#{config.resolved_name}'")
      end

      def heartbeat!
        config = Profiler.configuration
        uri = master_uri("heartbeat")
        body = { name: config.resolved_name }.to_json
        resp = Net::HTTP.post(uri, body, request_headers)
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
        Thread.new do
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
