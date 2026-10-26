# frozen_string_literal: true

require "concurrent-ruby"

module Profiler
  module Cluster
    class TokenCache
      TTL = 600 # 10 minutes

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
        cleanup_expired if @cache.size > 1000
        @cache[token] = { slave_name: slave_name, expires_at: Time.now + TTL }
      end

      def invalidate(token)
        @cache.delete(token)
      end

      private

      def cleanup_expired
        now = Time.now
        @cache.delete_if { |_, entry| now > entry[:expires_at] }
      end
    end
  end
end
