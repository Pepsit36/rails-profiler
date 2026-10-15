# frozen_string_literal: true

require "spec_helper"

# Regression specs for SEC-03, from the fourth review of the fix: procs of
# arity 3 receive the original params, as ActiveSupport::ParameterFilter
# gives them.
RSpec.describe "Sensitive data redaction, fourth review follow-up" do
  def fake_rails(filters)
    config = Struct.new(:filter_parameters).new(filters)
    Struct.new(:application, :logger).new(Struct.new(:config).new(config), nil)
  end

  def reference(filters, hash)
    ActiveSupport::ParameterFilter.new(filters + Profiler.configuration.filter_parameters,
                                       mask: Profiler::Redaction::MASK).filter(hash)
  end

  let(:by_type) { ->(key, value, params) { value.replace("[CARD]") if key == "number" && params["type"] == "card" } }
  let(:fetching) { ->(key, value, params) { value.replace("[CARD]") if key == "number" && params.fetch("type") == "card" } }
  let(:params) { { "type" => "card", "number" => "4111111111111111", "holder" => { "name" => "Alice" } } }

  it "gives a proc of arity 3 the original params" do
    stub_const("Rails", fake_rails([by_type]))

    expect(Profiler::Redaction.filter_hash(params)).to eq(reference([by_type], params))
    expect(Profiler::Redaction.filter_hash(params)["number"]).to eq("[CARD]")
  end

  it "lets a proc of arity 3 read any key of the original params" do
    stub_const("Rails", fake_rails([fetching]))

    expect(Profiler::Redaction.filter_hash(params)).to eq(reference([fetching], params))
  end

  # Random trees of hashes, arrays and strings: the profiler's filter must
  # give what ParameterFilter gives, procs of arity 2 and 3 included.
  it "matches ParameterFilter on random trees" do
    keys = %w[id name password Token user secret number type note cvv items]
    random = Random.new(42)
    tree = lambda do |depth|
      roll = random.rand(10)
      if depth.zero? || roll < 5
        "v#{random.rand(1000)}"
      elsif roll < 7
        Array.new(random.rand(3)) { tree.(depth - 1) }
      else
        Array.new(random.rand(1..4)) { [keys.sample(random: random), tree.(depth - 1)] }.to_h
      end
    end
    upcase = ->(key, value) { value.upcase! if key.to_s == "name" }
    with_params = ->(key, value, original) { value.prepend("t:") if key.to_s == "note" && original.key?("type") }
    filters = [:password, /tok/i, "user.secret", upcase, with_params]
    stub_const("Rails", fake_rails(filters))

    500.times do
      hash = Array.new(random.rand(1..5)) { [keys.sample(random: random), tree.(3)] }.to_h
      expect(Profiler::Redaction.filter_hash(hash)).to eq(reference(filters, hash)), hash.inspect
    end
  end
end
