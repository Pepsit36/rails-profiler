# frozen_string_literal: true

require_relative "../../../../lib/profiler/cluster/security"

module Profiler
  module Api
    class ClusterController < Profiler::ApplicationController
      SLAVE_ACTIONS = %w[register heartbeat].freeze

      def register
        name = params[:name].to_s
        url  = params[:url].to_s

        if name.empty? || url.empty?
          return render json: { error: "name and url are required" }, status: :unprocessable_entity
        end

        if (reason = Cluster::Security.slave_url_denial(url))
          return render json: { error: reason }, status: :unprocessable_entity
        end

        Profiler.slave_registry.register(name: name, url: Cluster::Security.normalized_url(url))
        render json: { ok: true, name: name }
      end

      def heartbeat
        name = params[:name].to_s
        entry = Profiler.slave_registry.heartbeat(name)
        if entry.nil?
          render json: { error: "Unknown slave — please re-register" }, status: :not_found
        else
          render json: { ok: true }
        end
      end

      def slaves
        render json: { slaves: Profiler.slave_registry.all }
      end

      private

      # A slave is a server, often on another host, not a browser: it proves itself with the
      # shared secret instead of the access guard and the forgery header. Without
      # cluster_require_secret, and with no secret configured, the guard of the other
      # endpoints applies, as in 0.30.6.
      def authorize_request
        return super unless secret_authenticated_action?
        return if Cluster::Security.request_secret_valid?(request)

        if (problem = Cluster::Security.secret_problem)
          deny("#{problem} on this master: cluster requests are refused")
        else
          deny("Missing or invalid #{Cluster::Security::SECRET_HEADER} header")
        end
      end

      # The secret is a custom header, which a cross-site page cannot send without a preflight.
      def verified_request?
        return Cluster::Security.request_secret_valid?(request) if secret_authenticated_action?

        super
      end

      def secret_authenticated_action?
        SLAVE_ACTIONS.include?(action_name) && Cluster::Security.secret_required?
      end
    end
  end
end
