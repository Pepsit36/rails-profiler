# frozen_string_literal: true

require "concurrent-ruby"

module Profiler
  module Cluster
    class TokenCache
      TTL = 600 # 10 minutes
      MAX_ENTRIES = 1000

      def initialize
        @cache = Concurrent::Map.new
      end

      def fetch(token)
        entry = @cache[token]
        if entry.nil? || Time.now > entry[:expires_at]
          @cache.delete(token)
          return nil
        end

        entry[:slave_name]
      end

      def store(token, slave_name)
        cleanup_expired if @cache.size >= MAX_ENTRIES
        @cache[token] = { slave_name: slave_name, expires_at: Time.now + TTL }
      end

      def invalidate(token)
        @cache.delete(token)
      end

      private

      def cleanup_expired
        now = Time.now
        @cache.each_pair { |token, entry| @cache.delete(token) if now > entry[:expires_at] }
      end
    end
  end
end
