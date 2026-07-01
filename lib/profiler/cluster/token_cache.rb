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
        return nil if entry.nil? || Time.now > entry[:expires_at]

        entry[:slave_name]
      end

      def store(token, slave_name)
        @cache[token] = { slave_name: slave_name, expires_at: Time.now + TTL }
      end

      def invalidate(token)
        @cache.delete(token)
      end
    end
  end
end
