# frozen_string_literal: true

require "spec_helper"
require "profiler/sse/redis_event_bus"

RSpec.describe Profiler::SSE::RedisEventBus do
  subject(:bus) { described_class.instance }

  # Just what the bus uses of a Redis client, with the replies redis-rb gives.
  let(:redis) do
    Class.new do
      attr_reader :values, :ttls

      def initialize
        @values = {}
        @ttls = {}
      end

      def multi
        values = @values
        ttls = @ttls
        replies = []
        transaction = Object.new
        transaction.define_singleton_method(:incr) { |key| replies << (values[key] = values[key].to_i + 1) }
        transaction.define_singleton_method(:expire) { |key, ttl| replies << !!(ttls[key] = ttl) }
        yield transaction
        replies
      end

      def get(key)
        @values[key]&.to_s
      end
    end.new
  end

  before do
    allow(Profiler).to receive(:storage).and_return(instance_double(Profiler::Storage::RedisStore, redis: redis))
  end

  it "counts the saves of a token in Redis, where every process sees them" do
    expect(bus.broadcast("tok")).to eq(1)
    expect(bus.broadcast("tok")).to eq(2)

    expect(bus.version("tok")).to eq(2)
    expect(redis.values).to eq("profiler:events:tok" => 2)
  end

  it "keeps the count as long as a profile is kept" do
    bus.broadcast("tok")

    expect(redis.ttls).to eq("profiler:events:tok" => 24 * 60 * 60)
  end

  it "is 0 for a token never saved" do
    expect(bus.version("tok")).to eq(0)
  end

  it "reads a Redis that fails as no newer save, at once" do
    allow(redis).to receive(:get).and_raise(Redis::CannotConnectError)

    expect(bus.version("tok")).to eq(0)
  end

  it "starts no thread and holds no connection of its own" do
    expect { bus.broadcast("tok") && bus.version("tok") }.not_to(change { Thread.list.size })
  end
end
