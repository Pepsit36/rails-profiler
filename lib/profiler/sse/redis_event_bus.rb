# frozen_string_literal: true

require "singleton"
require "securerandom"
require "timeout"
require "set"
require "json"
require "concurrent"

module Profiler
  module SSE
    class RedisEventBus
      include Singleton

      CHANNEL_PREFIX = "profiler:events"

      def initialize
        @subscriptions = Concurrent::Hash.new
        @listener_thread = nil
        @listener_mutex = Mutex.new
      end

      def subscribe(token, collectors)
        id = SecureRandom.uuid
        @subscriptions[id] = { token: token, collectors: Set.new(collectors.map(&:to_s)), queue: Queue.new }
        ensure_listener_running
        id
      end

      def unsubscribe(id)
        @subscriptions.delete(id)
      end

      def broadcast(token, collectors)
        payload = { token: token, collectors: collectors.map(&:to_s), timestamp: Time.now.to_f }.to_json
        publish_redis_client.publish("#{CHANNEL_PREFIX}:#{token}", payload)
      end

      def wait_for_event(id, timeout: 30)
        sub = @subscriptions[id]
        return nil unless sub
        Timeout.timeout(timeout) { sub[:queue].pop }
      rescue Timeout::Error
        nil
      end

      private

      def publish_redis_client
        Profiler.storage.redis
      end

      def ensure_listener_running
        @listener_mutex.synchronize do
          return if @listener_thread&.alive?

          @listener_thread = Thread.new do
            # Use a dedicated connection for blocking psubscribe
            Profiler.storage.redis.dup.psubscribe("#{CHANNEL_PREFIX}:*") do |on|
              on.pmessage do |_pattern, _channel, message|
                payload = JSON.parse(message, symbolize_names: true)
                token = payload[:token]
                changed = Set.new(payload[:collectors].map(&:to_s))

                @subscriptions.each_value do |sub|
                  next unless sub[:token] == token
                  next if sub[:collectors].any? && (sub[:collectors] & changed).empty?
                  sub[:queue] << { token: token, collectors: changed.to_a, timestamp: payload[:timestamp] }
                end
              end
            end
          rescue StandardError
            # Thread restarts on the next subscribe call
          end
        end
      end
    end
  end
end
