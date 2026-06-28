# frozen_string_literal: true

require "singleton"
require "securerandom"
require "timeout"
require "set"
require "concurrent"

module Profiler
  module SSE
    class EventBus
      include Singleton

      def initialize
        @subscriptions = Concurrent::Hash.new
      end

      def subscribe(token, collectors)
        id = SecureRandom.uuid
        @subscriptions[id] = { token: token, collectors: Set.new(collectors.map(&:to_s)), queue: Queue.new }
        id
      end

      def unsubscribe(id)
        @subscriptions.delete(id)
      end

      def broadcast(token, collectors)
        changed = Set.new(collectors.map(&:to_s))
        @subscriptions.each_value do |sub|
          next unless sub[:token] == token
          # Empty collector set means "match all"; non-empty set filters by intersection.
          next if sub[:collectors].any? && (sub[:collectors] & changed).empty?
          sub[:queue] << { token: token, collectors: changed.to_a, timestamp: Time.now.to_f }
        end
      end

      def wait_for_event(id, timeout: 30)
        sub = @subscriptions[id]
        return nil unless sub
        Timeout.timeout(timeout) { sub[:queue].pop }
      rescue Timeout::Error
        nil
      end
    end
  end
end
