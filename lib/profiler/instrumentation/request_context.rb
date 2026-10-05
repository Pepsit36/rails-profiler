# frozen_string_literal: true

require_relative "../collectors/scoped_notifications"

module Profiler
  module Instrumentation
    # What a request being profiled hands to the work it starts on other threads: its
    # notification scope and the collectors that record through thread-local slots.
    #
    # It travels with the work, not with a thread: a thread the application starts with
    # Thread.new gets it for the life of its block (ThreadContextPropagation), a task posted to a
    # concurrent-ruby executor for the time the task runs (ExecutorContextPropagation). A thread
    # an executor creates to run tasks, a pool worker or a Puma thread, gets nothing: it outlives
    # the request and serves others.
    module RequestContext
      KEYS = %i[
        profiler_http_collector
        profiler_flamegraph_collector
      ].freeze

      # The files whose code calls Thread.new to create the threads of a pool: concurrent-ruby's
      # executors (a worker of RubyThreadPoolExecutor, the thread of SimpleExecutorService) and
      # Puma's thread pool.
      POOL_FILES = %r{/concurrent/executor/[a-z_]+\.rb\z|/puma/thread_pool\.rb\z}

      module_function

      # The current request's context, or nil outside of one.
      def capture
        slots = KEYS.filter_map do |key|
          value = Thread.current[key]
          [key, value] unless value.nil?
        end.to_h
        scope = Collectors::ScopedNotifications.current
        return nil if slots.empty? && scope.nil?

        { slots: slots, scope: scope }.freeze
      end

      # Runs the block in +context+, and gives the thread back what it had before.
      def with(context)
        return yield if context.nil?

        previous_slots = KEYS.to_h { |key| [key, Thread.current[key]] }
        previous_scope = Collectors::ScopedNotifications.adopted
        KEYS.each { |key| Thread.current[key] = context[:slots][key] }
        Collectors::ScopedNotifications.adopt(context[:scope])
        begin
          yield
        ensure
          previous_slots.each { |key, value| Thread.current[key] = value }
          Collectors::ScopedNotifications.adopt(previous_scope)
        end
      end

      # Whether the thread being created is one of a pool's: then it must not inherit. Only the
      # code that calls Thread.new counts; a thread the application starts from a task, or from a
      # request a pool thread serves, is the request's.
      def creating_pool_thread?
        # 0 is this method, 1 the Thread#initialize patch, 2 Thread.new, which reports the file
        # of the code that called it.
        location = caller_locations(2, 1)&.first
        location ? POOL_FILES.match?(location.path.to_s) : false
      end
    end
  end
end
