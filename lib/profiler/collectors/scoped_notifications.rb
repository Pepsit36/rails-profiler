# frozen_string_literal: true

require_relative "../current_context"

module Profiler
  module Collectors
    # ActiveSupport::Notifications subscriptions scoped to the request that made them.
    #
    # The notifications bus is process-wide: a collector subscribed on it directly receives the
    # events of every thread, another request's SQL included. Here the process holds one
    # subscriber per event name, whatever the number of requests being profiled, and hands each
    # event to the handlers of the execution context that emitted it only.
    #
    # The context is ActiveSupport::IsolatedExecutionState, which Rails itself scopes its
    # connections and instrumenters to: a thread, or a fiber with
    # config.active_support.isolation_level = :fiber. ActionController::Live shares it with the
    # thread it runs the action in, and ThreadContextPropagation hands it to the threads a request
    # starts. A thread with no scope of its own that carries a profile's token
    # (Profiler::CurrentContext), as a server thread iterating a streamed body does, gets the scope
    # opened under that token. A scope lasts until its last handler is released, after the
    # response body is closed for a streamed response, wherever that release runs; the next
    # request of the thread then opens a new one, so a thread still holding the old scope, or the
    # old token, receives nothing more.
    module ScopedNotifications
      STATE_KEY = :profiler_notification_scope
      # Fiber storage, inherited by the fibers and threads a fiber creates: Ruby 3.2+.
      FIBER_STORAGE = Fiber.respond_to?(:[])

      # The handlers of one request, by event name.
      class Scope
        attr_reader :token, :owner

        def initialize(token = nil)
          @token = token
          @owner = Thread.current
          @mutex = Mutex.new
          @handlers = {}
          @size = 0
          @closed = false
        end

        def closed?
          @closed
        end

        def handlers_for(event)
          @handlers[event]
        end

        # False when the scope was closed meanwhile: the caller opens a new one.
        def add(event, handler)
          @mutex.synchronize do
            return false if @closed

            @handlers[event] = [*@handlers[event], handler].freeze
            @size += 1
            true
          end
        end

        # nil when the handler was not there (released already), :last when it was the scope's
        # last one, :removed otherwise.
        def remove(event, handler)
          @mutex.synchronize do
            list = @handlers[event]
            return nil unless list&.any? { |h| h.equal?(handler) }

            rest = list.reject { |h| h.equal?(handler) }
            rest.empty? ? @handlers.delete(event) : @handlers[event] = rest.freeze
            @size -= 1
            @closed = @size.zero?
            @closed ? :last : :removed
          end
        end
      end

      Handle = Struct.new(:scope, :event, :handler)

      @mutex = Mutex.new
      @subscribers = {} # event name => [subscriber, handler count]
      @by_token = {}.freeze # profile token => the scope opened under it, replaced on write

      class << self
        # Calls +handler+ with (name, started, finished, id, payload), monotonic times, for each
        # +event+ the current execution context emits until the handle is unsubscribed.
        def subscribe(event, &handler)
          # The process subscriber first: when the notifier fails, nothing was added to the scope.
          retain(event)
          scope = current_scope
          scope = open_scope until scope.add(event, handler)
          Handle.new(scope, event, handler)
        end

        # Safe from any thread, and more than once.
        def unsubscribe(handle)
          return unless handle

          removed = handle.scope.remove(handle.event, handle.handler)
          return unless removed

          release(handle.event)
          close_scope(handle.scope) if removed == :last
        end

        # The current context's scope, for ThreadContextPropagation to hand to a new thread: the
        # one of its execution state, or else the one a fiber inherited from the fiber that created
        # it (Fiber storage, Ruby 3.2+). With isolation_level = :fiber, a fiber the request creates
        # (render stream: true renders the layout in one) has no execution state of its own.
        def current
          scope = state[STATE_KEY]
          scope = fiber_scope if scope.nil? || scope.closed?
          scope unless scope.nil? || scope.closed?
        end

        # The scope the current context's events go to.
        def routed_scope
          scope = current
          return scope if scope

          token = CurrentContext.token
          @by_token[token] if token
        end

        def adopt(scope)
          state[STATE_KEY] = scope
          Fiber[STATE_KEY] = scope if FIBER_STORAGE
        end

        # A thread a pool creates inherits the Fiber storage of the code that created it, which
        # may be a request's: it must not keep that request's scope.
        def forget_inherited_scope
          Fiber[STATE_KEY] = nil if FIBER_STORAGE && !Fiber[STATE_KEY].nil?
        end

        # Runs the block with a scope of its own when the current one was opened by another thread:
        # a job a pool performs for the request that enqueued it (ActiveJob's :async adapter) is
        # profiled apart from that request, which may still be running. A job performed inline,
        # on the request's own thread, keeps sharing its scope, as it always did.
        def apart_from_other_threads
          scope = current
          return yield if scope.nil? || scope.owner.equal?(Thread.current)

          previous = adopted
          adopt(nil)
          begin
            yield
          ensure
            restore(previous)
          end
        end

        # What the current context holds, closed or not, for RequestContext to put back.
        def adopted
          [state[STATE_KEY], fiber_scope]
        end

        def restore(adopted)
          state[STATE_KEY], inherited = adopted
          Fiber[STATE_KEY] = inherited if FIBER_STORAGE
        end

        private

        def state
          defined?(ActiveSupport::IsolatedExecutionState) ? ActiveSupport::IsolatedExecutionState : Thread.current
        end

        def current_scope
          current || open_scope
        end

        def fiber_scope
          Fiber[STATE_KEY] if FIBER_STORAGE
        end

        def open_scope
          token = CurrentContext.token
          scope = Scope.new(token)
          if token
            @mutex.synchronize { @by_token = @by_token.merge(token => scope).freeze }
          end
          adopt(scope)
          scope
        end

        def close_scope(scope)
          state[STATE_KEY] = nil if state[STATE_KEY].equal?(scope)
          Fiber[STATE_KEY] = nil if FIBER_STORAGE && fiber_scope.equal?(scope)
          return unless scope.token

          @mutex.synchronize do
            @by_token = @by_token.reject { |_, s| s.equal?(scope) }.freeze if @by_token[scope.token].equal?(scope)
          end
        end

        def retain(event)
          @mutex.synchronize do
            entry = (@subscribers[event] ||= [subscribe_process(event), 0])
            entry[1] += 1
          end
        end

        def release(event)
          @mutex.synchronize do
            entry = @subscribers[event]
            return unless entry

            entry[1] -= 1
            return unless entry[1] <= 0

            ActiveSupport::Notifications.unsubscribe(entry[0])
            @subscribers.delete(event)
          end
        end

        def subscribe_process(event)
          ActiveSupport::Notifications.monotonic_subscribe(event) do |name, started, finished, id, payload|
            routed_scope&.handlers_for(event)&.each do |handler|
              handler.call(name, started, finished, id, payload)
            rescue StandardError => e
              # Never into the application's query, nor at the expense of the other collectors.
              Profiler.log_error("collector failed on #{event}", e)
            end
          end
        end
      end
    end
  end
end
