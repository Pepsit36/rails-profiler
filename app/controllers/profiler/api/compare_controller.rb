# frozen_string_literal: true

module Profiler
  module Api
    class CompareController < ApplicationController
      skip_before_action :verify_authenticity_token

      # Only the node names of config.peers are read from the request; a URL is never accepted.
      def show
        token_a = params[:a]
        token_b = params[:b]

        errors = []
        errors << "Missing parameter: a" unless token_a.present?
        errors << "Missing parameter: b" unless token_b.present?

        if errors.any?
          render json: { errors: errors }, status: :unprocessable_entity and return
        end

        node_a = params[:node_a].to_s
        node_b = params[:node_b].to_s
        if token_a == token_b && node_a == node_b
          render json: { errors: ["Cannot compare a profile with itself"] }, status: :unprocessable_entity and return
        end

        render json: ProfileComparison.call(token_a.to_s, token_b.to_s, node_a: node_a, node_b: node_b)
      rescue ProfileComparison::NotFound => e
        render json: { errors: e.message.split("\n") }, status: :not_found
      rescue Profiler::Error => e
        render json: { errors: [e.message] }, status: :bad_gateway
      end

      # The nodes a profile can be read from: this instance, then the names of config.peers.
      def nodes
        render json: { nodes: [Peers::LOCAL_NODE] + Peers.names }
      rescue Profiler::Error => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      end
    end
  end
end
