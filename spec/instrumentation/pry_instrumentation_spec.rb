# frozen_string_literal: true

require "spec_helper"
require "pry"
require "profiler/console_profiler"
require "profiler/instrumentation/irb_instrumentation"
require "profiler/instrumentation/pry_instrumentation"

RSpec.describe Profiler::Instrumentation::PryInstrumentation do
  before do
    Profiler.configure do |c|
      c.enabled = true
      c.track_console = true
      c.storage = :memory
      c.track_memory = false
      c.track_http = false
    end
  end

  # The real Pry#evaluate_ruby, instrumented on this instance only so that nothing leaks into other examples.
  let(:pry) do
    Pry.new.tap { |instance| instance.singleton_class.prepend(described_class) }
  end

  let(:sql_expression) do
    'ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM users", name: "Load", binds: []) { 42 }'
  end

  def console_profiles
    Profiler.storage.list.select { |p| p.profile_type == "console" }
  end

  it "records a console profile with the expression, return value, status and SQL" do
    expect(pry.evaluate_ruby("#{sql_expression}\n")).to eq(42)

    expect(console_profiles.size).to eq(1)
    profile = console_profiles.first
    expect(profile.status).to eq(200)
    data = profile.collector_data("console")
    expect(data["expression"]).to eq(sql_expression)
    expect(data["return_value"]).to eq("42")
    expect(profile.collector_data("database")["total_queries"]).to eq(1)
  end

  it "does not profile blank input" do
    expect(Profiler::ConsoleProfiler).not_to receive(:profile)
    pry.evaluate_ruby("")
    pry.evaluate_ruby("  \n")
  end

  it "does not profile when track_console is false" do
    Profiler.configure { |c| c.track_console = false }
    expect(pry.evaluate_ruby("1")).to eq(1)
    expect(console_profiles).to be_empty
  end

  it "does not profile when the profiler is disabled" do
    Profiler.configure { |c| c.enabled = false }
    expect(pry.evaluate_ruby("1")).to eq(1)
    expect(console_profiles).to be_empty
  end

  context "when IRB and Pry both evaluate the same expression" do
    it "records it once" do
      irb_class = Class.new do
        def initialize(pry) = @pry = pry
        def evaluate(line, _line_no, *) = @pry.evaluate_ruby(line)
      end
      irb_class.prepend(Profiler::Instrumentation::IrbInstrumentation)

      irb_class.new(pry).evaluate(sql_expression, 1)
      expect(console_profiles.size).to eq(1)
    end

    it "releases the guard afterwards, even when the expression raises" do
      expect { Profiler::ConsoleProfiler.profile(expression: "boom") { raise "boom" } }.to raise_error("boom")
      pry.evaluate_ruby("2")
      expect(console_profiles.size).to eq(2)
    end
  end
end
