# frozen_string_literal: true

require "spec_helper"
require "socket"
require "profiler/instrumentation/thread_context_propagation"

# Thread.prepend has already run, from lib/profiler.rb, so every example here
# drives the real Thread.new rather than a stand-in.
RSpec.describe Profiler::Instrumentation::ThreadContextPropagation do
  let(:collector) { instance_double("Profiler::Collectors::HttpCollector") }

  def with_profiling_context
    Thread.current[:profiler_http_collector] = collector
    yield
  ensure
    described_class::PROPAGATED_KEYS.each { |key| Thread.current[key] = nil }
  end

  describe "the arguments of Thread.new" do
    it "reaches the block while a profile is being collected" do
      with_profiling_context do
        expect(Thread.new(1, 2, 3) { |a, b, c| [a, b, c] }.value).to eq([1, 2, 3])
      end
    end

    it "reaches the block when no profile is being collected" do
      expect(Thread.new(1, 2, 3) { |a, b, c| [a, b, c] }.value).to eq([1, 2, 3])
    end

    # The bare super path flattened a trailing keyword hash just as the wrapper did,
    # because the signature, not the wrapper, is what loses the keyword-ness. So this
    # held for every application loading the gem, on every Ruby, profile or no profile.
    it "stays keyword arguments when no profile is being collected either" do
      expect(Thread.new(1, key: 2) { |*args, **kwargs| [args, kwargs] }.value).to eq([[1], { key: 2 }])
    end

    it "reaches a block that splats them" do
      with_profiling_context do
        expect(Thread.new(1, 2, 3) { |*args| args }.value).to eq([1, 2, 3])
      end
    end

    it "stays keyword arguments rather than becoming a positional hash" do
      with_profiling_context do
        expect(Thread.new(1, key: 2) { |*args, **kwargs| [args, kwargs] }.value).to eq([[1], { key: 2 }])
      end
    end

    it "reaches a block that takes keyword arguments on their own" do
      with_profiling_context do
        expect(Thread.new(key: 2) { |hash| hash }.value).to eq({ key: 2 })
      end
    end

    it "is allowed to be empty" do
      with_profiling_context do
        expect(Thread.new { 42 }.value).to eq(42)
      end
    end
  end

  describe "the propagated context" do
    it "reaches the child thread" do
      with_profiling_context do
        expect(Thread.new { Thread.current[:profiler_http_collector] }.value).to be(collector)
      end
    end

    it "is cleared in the child thread once its block has returned" do
      with_profiling_context do
        thread = Thread.new { Thread.current[:profiler_http_collector] }
        expect(thread.value).to be(collector)

        described_class::PROPAGATED_KEYS.each do |key|
          expect(thread[key]).to be_nil
        end
      end
    end

    it "is left alone in the parent thread" do
      with_profiling_context do
        Thread.new { :done }.join
        expect(Thread.current[:profiler_http_collector]).to be(collector)
      end
    end
  end

  # Ruby refuses a Thread.new with no block. The patch used to hand the real
  # initialize a wrapper of its own in that case, which is a block, so the thread
  # started and the error never came, but only while a profile was being collected.
  describe "Thread.new with no block" do
    it "is refused while a profile is being collected" do
      with_profiling_context do
        expect { Thread.new }.to raise_error(ThreadError)
      end
    end

    it "is refused when no profile is being collected" do
      expect { Thread.new }.to raise_error(ThreadError)
    end
  end

  # Ruby 3.4 resolves the hostname of Socket.tcp in Ruby threads, for Happy
  # Eyeballs v2. socket.rb does
  #   Thread.new(*thread_args) { |*thread_args| resolve_hostname(*thread_args) }
  # so a Thread#initialize that drops the arguments leaves resolve_hostname with
  # none, kills both resolution threads on an ArgumentError, and leaves the name
  # unresolved. Ruby 3.3 has no Ruby level Happy Eyeballs and connects either way.
  describe "Socket.tcp while a profile is being collected" do
    # Short on purpose. Without resolv_timeout the broken path waits for ever on
    # IO.select, and a suite that hangs says less than one that goes red.
    let(:resolv_timeout) { 2 }
    let(:connect_timeout) { 2 }

    let!(:server) { TCPServer.new("127.0.0.1", 0) }
    let(:port) { server.addr[1] }

    after { server.close }

    # Pinned rather than read off the runner: RUBY_TCP_NO_FAST_FALLBACK=1 turns Happy
    # Eyeballs off while Socket still answers to tcp_fast_fallback, and the examples
    # below would then pass, or fail, for a reason that has nothing to do with this
    # patch. The version gate stays on respond_to?, which is what 3.3 lacks.
    before do
      next unless Socket.respond_to?(:tcp_fast_fallback)

      @fast_fallback_was = Socket.tcp_fast_fallback
      Socket.tcp_fast_fallback = true
    end

    after do
      Socket.tcp_fast_fallback = @fast_fallback_was if Socket.respond_to?(:tcp_fast_fallback)
    end

    it "connects to a local server addressed by hostname" do
      with_profiling_context do
        socket = Socket.tcp("localhost", port, resolv_timeout: resolv_timeout, connect_timeout: connect_timeout)
        expect(socket).to be_a(Socket)
        socket.close
      end
    end

    # Guards the example above against passing for the wrong reason: if the
    # hostname were resolved inline, nothing would go through Thread.new and the
    # connection would succeed with or without the fix.
    it "hands the hostname to resolution threads", if: Socket.respond_to?(:tcp_fast_fallback) do
      thread_arguments = []
      allow(Thread).to receive(:new).and_wrap_original do |original, *args, &block|
        thread_arguments << args
        original.call(*args, &block)
      end

      with_profiling_context do
        socket = Socket.tcp("localhost", port, resolv_timeout: resolv_timeout, connect_timeout: connect_timeout)
        socket.close
      rescue SystemCallError, SocketError
        # Whether the connection succeeds is the example above. This one only asks
        # what Thread.new was called with, and says so even when the connect fails.
        nil
      end

      expect(thread_arguments).to include([:ipv4, "localhost", port, anything])
    end
  end

  # A request whose collectors only listen to notifications (a job, a test, a console
  # expression) has a notification scope and none of PROPAGATED_KEYS: the wrapper runs then too.
  describe "while only notifications are scoped to the request" do
    let(:described_scope_key) { Profiler::Collectors::ScopedNotifications::STATE_KEY }

    def with_notification_scope
      handle = Profiler::Collectors::ScopedNotifications.subscribe("sql.active_record") { |*| }
      yield
    ensure
      Profiler::Collectors::ScopedNotifications.unsubscribe(handle)
    end

    it "hands the scope to the child thread, and takes it back once its block has returned" do
      with_notification_scope do
        scope = Profiler::Collectors::ScopedNotifications.current
        child = Thread.new { [Profiler::Collectors::ScopedNotifications.current, Thread.current] }
        seen, thread = child.value

        expect(seen).to equal(scope)
        expect(thread.active_support_execution_state.to_h[described_scope_key]).to be_nil
      end
    end

    it "keeps the arguments of Thread.new, keyword arguments included" do
      with_notification_scope do
        expect(Thread.new(1, key: 2) { |*args, **kwargs| [args, kwargs] }.value).to eq([[1], { key: 2 }])
        expect(Thread.new(1, 2, 3) { |*args| args }.value).to eq([1, 2, 3])
      end
    end

    it "connects to a local server addressed by hostname, which Ruby 3.4 resolves in threads" do
      server = TCPServer.new("127.0.0.1", 0)
      with_notification_scope do
        socket = Socket.tcp("localhost", server.addr[1], resolv_timeout: 2, connect_timeout: 2)
        expect(socket).to be_a(Socket)
        socket.close
      end
    ensure
      server&.close
    end
  end
end
