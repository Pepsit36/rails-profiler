# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "tmpdir"
require "active_support/core_ext/object/json" # what a Rails application has loaded
require "profiler/collectors/dump_collector"

# A dump is stored as its formatted text: the object itself, which can refer to itself or hold
# what JSON cannot write, never reaches the store.
RSpec.describe Profiler::Collectors::DumpCollector do
  include Rack::Test::Methods

  # An object that refers to itself through an instance variable.
  class SelfReferencingNode
    attr_accessor :parent, :name

    def initialize(name)
      @name = name
      @parent = self
    end
  end

  # An object whose own inspect walks its children without noticing the cycle.
  class RecursiveInspectNode
    attr_accessor :child

    def inspect
      "#<RecursiveInspectNode child=#{child.inspect}>"
    end
  end

  let(:dumped) { [] }
  let(:inner_app) do
    values = dumped
    lambda do |_env|
      values.each { |value| Profiler.dump(value, "value") }
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end

  def app
    Profiler::Middleware::ProfilerMiddleware.new(inner_app)
  end

  def default_host
    "localhost"
  end

  around do |example|
    Dir.mktmpdir do |dir|
      Profiler.configure do |c|
        c.enabled = true
        c.track_memory = false
        c.track_http = false
        c.skip_paths = []
        c.collectors = [described_class]
      end
      Profiler.instance_variable_set(:@storage, Profiler::Storage::FileStore.new(path: dir))
      example.run
    end
  end

  after { Thread.current[:profiler_dumps] = nil }

  def stored_dumps
    token = last_response.headers["X-Profiler-Token"]
    expect(token).not_to be_nil
    Profiler.storage.load(token).collector_data("dump")["dumps"]
  end

  it "saves the profile of a request that dumps an object referring to itself" do
    dumped << SelfReferencingNode.new("root")

    get "/cyclic"

    expect(last_response.status).to eq(200)
    expect(stored_dumps.first["formatted"]).to start_with("#<SelfReferencingNode:0x").and include('@name="root"')
  end

  it "saves the profile of a request that dumps an Array or a Hash holding itself" do
    array = [1]
    array << array
    hash = { "a" => 1 }
    hash["self"] = hash
    dumped.push(array, hash)

    get "/cyclic"

    expect(last_response.status).to eq(200)
    formatted = stored_dumps.map { |dump| dump["formatted"] }
    expect(formatted.first).to eq("[1, [...]]")
    # Ruby 3.4 spaces the => of Hash#inspect, 3.3 does not.
    expect(formatted.last).to match(/\A\{"a" ?=> ?1, "self" ?=> ?\{\.\.\.\}\}\z/)
  end

  it "stores no raw value next to the formatted one" do
    dumped << { "id" => 1 }

    get "/plain"

    expect(stored_dumps.first.keys).not_to include("value")
  end

  it "says the value could not be formatted when its inspect recurses without end" do
    node = RecursiveInspectNode.new
    node.child = node
    outer = SelfReferencingNode.new(node)
    dumped << outer

    get "/recursive"

    expect(last_response.status).to eq(200)
    expect(stored_dumps.first["formatted"]).to eq("[Error formatting value: stack level too deep]")
  end
end
