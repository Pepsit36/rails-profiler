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
        return nil if entry.nil?

        if Time.now > entry[:expires_at]
          @cache.delete_pair(token, entry)
          return nil
        end

        entry[:slave_name]
      end

      def store(token, slave_name)
        make_room if @cache.size >= MAX_ENTRIES
        @cache[token] = { slave_name: slave_name, expires_at: Time.now + TTL }
      end

      def invalidate(token)
        @cache.delete(token)
      end

      private

      # Drops the expired entries, then the oldest live ones, until there is room for one more.
      def make_room
        now = Time.now
        @cache.each_pair { |token, entry| @cache.delete_pair(token, entry) if now > entry[:expires_at] }
        excess = @cache.size - MAX_ENTRIES + 1
        return unless excess.positive?

        pairs = []
        @cache.each_pair { |token, entry| pairs << [token, entry] }
        oldest = pairs.min_by(excess) { |_token, entry| entry[:expires_at] }
        oldest.each { |token, entry| @cache.delete_pair(token, entry) }
      end
    end
  end
end
