# frozen_string_literal: true

require "concurrent-ruby"
require_relative "base_store"
require_relative "../models/profile"

module Profiler
  module Storage
    class MemoryStore < BaseStore
      def initialize(options = {})
        @profiles = Concurrent::Hash.new
        @max_profiles = options[:max_profiles] || Profiler.configuration.max_profiles || 100
      end

      def do_save(token, profile)
        cleanup_if_needed
        @profiles[token] = serialize_profile(profile)
        token
      end

      def load(token)
        return nil unless Token.valid?(token)

        data = @profiles[token]
        return nil unless data

        deserialize_profile(data)
      end

      def list(limit: 50, offset: 0)
        @profiles.values
                .map { |data| deserialize_profile(data) }
                .sort_by { |p| p.started_at }
                .reverse
                .drop(offset)
                .take(limit)
      end

      def cleanup(older_than: 24 * 60 * 60)
        cutoff_time = Time.now - older_than
        @profiles.delete_if do |_token, data|
          profile = deserialize_profile(data)
          profile.started_at < cutoff_time
        end
      end

      def find_by_parent(parent_token)
        return [] unless Token.valid?(parent_token)

        @profiles.values
                .map { |data| deserialize_profile(data) }
                .select { |profile| profile.parent_token == parent_token }
                .sort_by { |profile| profile.started_at }
      end

      def delete(token)
        return unless Token.valid?(token)

        @profiles.delete(token)
      end

      def clear(type: nil)
        if type.nil?
          @profiles.clear
        else
          @profiles.delete_if do |_token, data|
            deserialize_profile(data).profile_type == type.to_s
          end
        end
      end

      private

      def cleanup_if_needed
        return if @profiles.size < @max_profiles

        # Remove oldest profiles until we're under the limit
        profiles_to_remove = @profiles.size - (@max_profiles * 0.8).to_i
        return if profiles_to_remove <= 0

        sorted_tokens = @profiles.map do |token, data|
          profile = deserialize_profile(data)
          [token, profile.started_at]
        end.sort_by { |_, time| time }.map(&:first)

        sorted_tokens.take(profiles_to_remove).each do |token|
          @profiles.delete(token)
        end
      end

      def serialize_profile(profile)
        profile.to_h
      end

      def deserialize_profile(data)
        Models::Profile.from_hash(data)
      end
    end
  end
end
