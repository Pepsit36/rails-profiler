# frozen_string_literal: true

require "redis"
require "json"
require_relative "base_store"
require_relative "../models/profile"

module Profiler
  module Storage
    class RedisStore < BaseStore
      DEFAULT_TTL = 24 * 60 * 60 # 24 hours

      attr_reader :redis

      def initialize(options = {})
        @redis = options[:redis] || build_redis_client(options)
        @ttl = options[:ttl] || DEFAULT_TTL
        @key_prefix = options[:key_prefix] || "profiler"
      end

      def do_save(token, profile)
        key = profile_key(token)
        @redis.setex(key, @ttl, profile.to_json)

        # Add to sorted set for listing
        @redis.zadd(list_key, profile.started_at.to_f, token)

        token
      end

      def load(token)
        return nil unless Token.valid?(token)

        key = profile_key(token)
        json_data = @redis.get(key)
        return nil unless json_data

        Models::Profile.from_json(json_data)
      rescue => e
        warn "Failed to load profile #{token}: #{e.message}"
        nil
      end

      def list(limit: 50, offset: 0)
        tokens = @redis.zrevrange(list_key, offset, offset + limit - 1)
        tokens.map { |token| load(token) }.compact
      end

      def cleanup(older_than: 24 * 60 * 60)
        cutoff_time = Time.now.to_f - older_than
        @redis.zremrangebyscore(list_key, "-inf", cutoff_time)
      end

      def find_by_parent(parent_token)
        return [] unless Token.valid?(parent_token)

        # Get all tokens from the sorted set
        tokens = @redis.zrange(list_key, 0, -1)

        # Load each profile and filter by parent_token
        tokens.map { |token| load(token) }
              .compact
              .select { |profile| profile.parent_token == parent_token }
              .sort_by { |profile| profile.started_at }
      end

      def delete(token)
        return unless Token.valid?(token)

        @redis.del(profile_key(token))
        @redis.zrem(list_key, token)
      end

      def clear(type: nil)
        tokens = @redis.zrange(list_key, 0, -1)
        tokens.each do |token|
          if type.nil?
            @redis.del(profile_key(token))
            @redis.zrem(list_key, token)
          else
            profile = load(token)
            if profile&.profile_type == type.to_s
              @redis.del(profile_key(token))
              @redis.zrem(list_key, token)
            end
          end
        end
      end

      private

      def build_redis_client(options)
        url = options[:url] || ENV["REDIS_URL"] || "redis://localhost:6379/0"
        Redis.new(url: url)
      end

      def profile_key(token)
        "#{@key_prefix}:#{token}"
      end

      def list_key
        "#{@key_prefix}:list"
      end
    end
  end
end
