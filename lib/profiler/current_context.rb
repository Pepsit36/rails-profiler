# frozen_string_literal: true

module Profiler
  module CurrentContext
    def self.token
      Thread.current[:profiler_token]
    end

    def self.token=(value)
      Thread.current[:profiler_token] = value
    end

    def self.clear
      Thread.current[:profiler_token] = nil
    end
  end
end
