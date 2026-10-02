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
      end

      expect(thread_arguments).to include([:ipv4, "localhost", port, anything])
    end
  end
end
