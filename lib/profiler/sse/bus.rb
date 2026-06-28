# frozen_string_literal: true

module Profiler
  module SSE
    def self.current
      if defined?(Profiler::Storage::RedisStore) && Profiler.storage.is_a?(Profiler::Storage::RedisStore)
        RedisEventBus.instance
      else
        EventBus.instance
      end
    end
  end
end
