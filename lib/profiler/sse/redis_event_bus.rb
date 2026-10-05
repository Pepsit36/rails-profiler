# frozen_string_literal: true

require "singleton"

module Profiler
  module SSE
    # The version of each profile's last save, kept in Redis next to the profiles so that every
    # process and every machine sharing them counts the same saves (see EventBus). A version is
    # a counter Redis increments, so versions only compare with versions of the same Redis.
    #
    # Nothing waits on Redis beyond its client's own timeouts: there is no subscription and no
    # listening thread, and a failing Redis reads as no newer save.
    class RedisEventBus
      include Singleton

      KEY_PREFIX = "profiler:events"
      # As long as RedisStore keeps a profile by default: past that, nobody looks at its page.
      TTL = 24 * 60 * 60

      def broadcast(token)
        key = key(token)
        version, _expire = redis.multi do |transaction|
          transaction.incr(key)
          transaction.expire(key, TTL)
        end
        version
      end

      # The version of the last save of +token+, 0 when none is known or Redis cannot be read.
      def version(token)
        redis.get(key(token)).to_i
      rescue StandardError
        0
      end

      private

      def key(token)
        "#{KEY_PREFIX}:#{token}"
      end

      def redis
        Profiler.storage.redis
      end
    end
  end
end
