# frozen_string_literal: true

require "redis"
require "json"
require_relative "base_store"
require_relative "summary"
require_relative "../models/profile"

module Profiler
  module Storage
    # Profiles as JSON strings with a TTL, listed by a sorted set scored by start time. Beside
    # them: a sorted set per profile type, a set of children per parent and the summary each list
    # shows, so that listing one type, a page of summaries or the children of a page reads only
    # what it returns; and at most max_profiles profiles, the oldest evicted first. Data written by
    # a version without these indexes is indexed once, on first use.
    class RedisStore < BaseStore
      DEFAULT_TTL = 24 * 60 * 60 # 24 hours
      INDEX_VERSION = "1"
      # Past max_profiles, the oldest profiles are evicted down to this share of it.
      LOW_WATER = 0.8

      attr_reader :redis

      def initialize(options = {})
        @redis = options[:redis] || build_redis_client(options)
        @ttl = options[:ttl] || DEFAULT_TTL
        @key_prefix = options[:key_prefix] || "profiler"
        @max_profiles = options.key?(:max_profiles) ? options[:max_profiles] : Profiler.configuration.max_profiles
        @indexed = false
      end

      def do_save(token, profile)
        ensure_index
        data = profile.to_h
        unindex(token, read_summary(token))
        @redis.setex(profile_key(token), @ttl, data.to_json)
        index(token, profile.started_at.to_f, Summary.build(data))
        evict_oldest
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

      # Newest first. summary: true reads the summaries only.
      def list(limit: 50, offset: 0, type: nil, summary: false)
        ensure_index
        tokens = @redis.zrevrange(type ? type_list_key(type) : list_key, offset, offset + limit - 1)
        return tokens.filter_map { |token| load(token) } unless summary

        summaries = tokens.empty? ? [] : @redis.mget(*tokens.map { |token| summary_key(token) })
        tokens.zip(summaries).filter_map do |token, json|
          next Summary.to_profile(JSON.parse(json)) if json

          profile = load(token)
          profile && Summary.to_profile(Summary.build(profile))
        end
      end

      def cleanup(older_than: 24 * 60 * 60)
        ensure_index
        cutoff_time = Time.now.to_f - older_than
        @redis.zrangebyscore(list_key, "-inf", cutoff_time).each { |token| remove(token) }
      end

      def find_by_parent(parent_token)
        return [] unless Token.valid?(parent_token)

        ensure_index
        @redis.smembers(children_key(parent_token))
              .filter_map { |token| load(token) if Token.valid?(token) }
              .select { |profile| profile.parent_token == parent_token }
              .sort_by(&:started_at)
      end

      def delete(token)
        return unless Token.valid?(token)

        ensure_index
        remove(token)
      end

      def clear(type: nil)
        ensure_index
        @redis.zrange(type ? type_list_key(type) : list_key, 0, -1).each { |token| remove(token) }
      end

      private

      def build_redis_client(options)
        url = options[:url] || ENV["REDIS_URL"] || "redis://localhost:6379/0"
        Redis.new(url: url)
      end

      def index(token, score, summary)
        type = (summary[:profile_type] || "http").to_s
        parent = summary[:parent_token]
        @redis.setex(summary_key(token), @ttl, JSON.generate(summary))
        @redis.zadd(list_key, score, token)
        @redis.zadd(type_list_key(type), score, token)
        @redis.sadd(types_key, type)
        return unless Token.valid?(parent)

        @redis.sadd(children_key(parent), token)
        @redis.expire(children_key(parent), @ttl)
      end

      # Takes token out of the type list and the children set its previous save put it in.
      def unindex(token, summary)
        return unless summary

        @redis.zrem(type_list_key(summary["profile_type"] || "http"), token)
        parent = summary["parent_token"]
        @redis.srem(children_key(parent), token) if Token.valid?(parent)
      end

      def remove(token)
        summary = read_summary(token)
        unindex(token, summary)
        @redis.smembers(types_key).each { |type| @redis.zrem(type_list_key(type), token) } unless summary
        @redis.del(profile_key(token), summary_key(token))
        @redis.zrem(list_key, token)
      end

      def read_summary(token)
        json = @redis.get(summary_key(token))
        json && JSON.parse(json)
      rescue JSON::ParserError
        nil
      end

      # ZCARD is O(1): the eviction costs nothing until the cap is passed.
      def evict_oldest
        return unless @max_profiles

        count = @redis.zcard(list_key)
        return if count <= @max_profiles

        keep = [(@max_profiles * LOW_WATER).floor, 1].max
        @redis.zrange(list_key, 0, count - keep - 1).each { |token| remove(token) }
      end

      # Indexes, once, the profiles saved by a version that kept only the list.
      def ensure_index
        return if @indexed
        return @indexed = true if @redis.get(index_version_key) == INDEX_VERSION

        @redis.zrange(list_key, 0, -1).each do |token|
          next unless Token.valid?(token)

          json = @redis.get(profile_key(token))
          next @redis.zrem(list_key, token) unless json

          profile = Models::Profile.from_json(json)
          index(token, profile.started_at.to_f, Summary.build(profile))
        rescue StandardError => e
          warn "RedisStore: could not index profile #{token}: #{e.message}"
        end
        @redis.set(index_version_key, INDEX_VERSION)
        @indexed = true
      end

      def profile_key(token)
        "#{@key_prefix}:#{token}"
      end

      def list_key
        "#{@key_prefix}:list"
      end

      def type_list_key(type)
        "#{@key_prefix}:list:#{type}"
      end

      def types_key
        "#{@key_prefix}:types"
      end

      def summary_key(token)
        "#{@key_prefix}:summary:#{token}"
      end

      def children_key(parent_token)
        "#{@key_prefix}:children:#{parent_token}"
      end

      def index_version_key
        "#{@key_prefix}:index_version"
      end
    end
  end
end
