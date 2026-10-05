# frozen_string_literal: true

require "redis"
require "json"
require "time"
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
      # Past max_profiles, the first saved profiles are evicted down to this share of it.
      LOW_WATER = 0.8
      # Indexing the data of an earlier version: tokens read per batch, and how long one process
      # holds the right to do it.
      INDEX_BATCH = 500
      INDEX_LOCK_SECONDS = 60

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
        evict_first_saved(token)
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

      # score: the start time, the order of the lists. saved_at: the order of the saves, which the
      # eviction follows.
      def index(token, score, summary, saved_at: Time.now.to_f, client: @redis)
        type = (summary[:profile_type] || summary["profile_type"] || "http").to_s
        parent = summary[:parent_token] || summary["parent_token"]
        client.setex(summary_key(token), @ttl, JSON.generate(summary))
        client.zadd(list_key, score, token)
        client.zadd(type_list_key(type), score, token)
        client.zadd(saved_key, saved_at, token)
        client.sadd(types_key, type)
        return unless Token.valid?(parent)

        client.sadd(children_key(parent), token)
        client.expire(children_key(parent), @ttl)
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
        @redis.zrem(saved_key, token)
      end

      def read_summary(token)
        json = @redis.get(summary_key(token))
        json && JSON.parse(json)
      rescue JSON::ParserError
        nil
      end

      # In the order of the saves, not of the starts: a job saved when it ends is a new profile,
      # and the one just saved (keep) is never evicted. ZCARD is O(1): the eviction costs nothing
      # until the cap is passed.
      def evict_first_saved(keep)
        return unless @max_profiles

        count = @redis.zcard(saved_key)
        return if count <= @max_profiles

        target = [(@max_profiles * LOW_WATER).floor, 1].max
        @redis.zrange(saved_key, 0, count - target - 1).each { |token| remove(token) unless token == keep }
      end

      # Indexes, once, the profiles saved by a version that kept only the list, which it never
      # pruned: the tokens started long before the TTL first, then the others read by batches.
      # One process does it, under a lock; the others go on meanwhile, with the list alone.
      def ensure_index
        return if @indexed
        return @indexed = true if @redis.get(index_version_key) == INDEX_VERSION
        return unless @redis.set(index_lock_key, Process.pid.to_s, nx: true, ex: INDEX_LOCK_SECONDS)

        begin
          # An hour of margin for a profile saved long after it started.
          @redis.zremrangebyscore(list_key, "-inf", Time.now.to_f - @ttl - 3600)
          @redis.zrange(list_key, 0, -1).each_slice(INDEX_BATCH) { |tokens| index_batch(tokens) }
          @redis.set(index_version_key, INDEX_VERSION)
          @indexed = true
        ensure
          @redis.del(index_lock_key)
        end
      end

      def index_batch(tokens)
        tokens = tokens.select { |token| Token.valid?(token) }
        return if tokens.empty?

        expired = []
        profiles = tokens.zip(@redis.mget(*tokens.map { |token| profile_key(token) })).filter_map do |token, json|
          if json.nil?
            expired << token
            next
          end

          # The summary from the parsed JSON, without building the Profile (and inflating its bodies).
          data = JSON.parse(json, symbolize_names: true)
          [token, data[:started_at] ? Time.parse(data[:started_at]).to_f : 0.0, Summary.build(data)]
        rescue StandardError => e
          warn "RedisStore: could not index profile #{token}: #{e.message}"
          nil
        end
        @redis.pipelined do |pipe|
          profiles.each do |token, started_at, summary|
            index(token, started_at, summary, saved_at: started_at, client: pipe)
          end
        end
        @redis.zrem(list_key, expired) unless expired.empty?
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

      def index_lock_key
        "#{@key_prefix}:index_lock"
      end

      def saved_key
        "#{@key_prefix}:saved"
      end
    end
  end
end
