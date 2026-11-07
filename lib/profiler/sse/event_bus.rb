# frozen_string_literal: true

require "singleton"

module Profiler
  module SSE
    # Remembers, per profile token, the version of its last save, so that a page showing the
    # profile can ask whether it changed since the version it holds. Nothing here waits: a
    # request asking for the version is answered at once, and the toolbar comes back later (see
    # Api::EventsController).
    #
    # A version is the time of the save in microseconds, so that versions from the worker
    # processes of one machine compare with each other: without Redis, each worker only knows
    # the saves it made, and a page sees a save when one of its questions reaches that worker.
    class EventBus
      include Singleton

      # The tokens remembered; the oldest saved is forgotten first. A forgotten token reads as
      # version 0, which is never newer than what a page holds, and its next save is seen again.
      MAX_TOKENS = 1000

      def initialize
        @versions = {}
        @generation = 0
        @mutex = Mutex.new
      end

      # Moves on every save this process announces, whatever the profile: a cheap way for a live
      # stream to know that something was saved, before it looks at what.
      def generation
        @mutex.synchronize { @generation }
      end

      def broadcast(token)
        now = Process.clock_gettime(Process::CLOCK_REALTIME, :microsecond)
        @mutex.synchronize do
          @generation += 1
          # Strictly increasing within the process, even for two saves in one microsecond.
          version = [now, @versions.delete(token).to_i + 1].max
          @versions[token] = version
          @versions.shift while @versions.size > MAX_TOKENS
          version
        end
      end

      # The version of the last save of +token+ seen by this process, 0 when none was.
      def version(token)
        @mutex.synchronize { @versions.fetch(token, 0) }
      end

      def reset!
        @mutex.synchronize do
          @versions.clear
          @generation = 0
        end
      end
    end
  end
end
