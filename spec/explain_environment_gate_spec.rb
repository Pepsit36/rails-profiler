# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "sqlite3"
require "tmpdir"
require "fileutils"
require_relative "support/rails_app"
require "profiler/explain_runner"
require "profiler/mcp/tools/explain_query"

# #53 case 7: PostgreSQL's EXPLAIN ANALYZE runs the query it explains, so Explain only runs in
# the development and test environments, even where an application sets enabled = true, unless
# config.allow_explain_outside_development says otherwise.
RSpec.describe "Explain outside development and test" do
  include Rack::Test::Methods

  let(:writing) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost", "HTTP_X_PROFILER_REQUEST" => "1" } }
  let(:storage) { Profiler::Storage::MemoryStore.new }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  def in_environment(name)
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new(name))
  end

  before(:all) do
    @dir = Dir.mktmpdir("profiler-explain-gate")
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(@dir, "gate.sqlite3"))
  end

  after(:all) do
    ActiveRecord::Base.remove_connection
    FileUtils.remove_entry(@dir)
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, storage)
  end

  def store_select
    profile = build_profile(collectors_data: { "database" => { "queries" => [{ "sql" => "SELECT 1", "binds" => [] }] } })
    storage.save(profile.token, profile)
    profile.token
  end

  describe Profiler::ExplainRunner, ".refusal" do
    it "allows development and test" do
      %w[development test].each do |name|
        in_environment(name)
        expect(described_class.refusal).to be_nil
      end
    end

    it "refuses production and any other environment, enabled or not" do
      %w[production staging].each do |name|
        in_environment(name)
        expect(described_class.refusal).to eq(described_class::OUTSIDE_DEVELOPMENT)
      end
    end

    it "refuses when the environment is unknown (no Rails)" do
      hide_const("Rails")

      expect(described_class.refusal).to eq(described_class::OUTSIDE_DEVELOPMENT)
    end

    it "allows every environment with config.allow_explain_outside_development = true" do
      in_environment("production")
      Profiler.configuration.allow_explain_outside_development = true

      expect(described_class.refusal).to be_nil
    end

    it "still refuses when the profiler is disabled, whatever the environment" do
      Profiler.configuration.enabled = false
      Profiler.configuration.allow_explain_outside_development = true

      expect(described_class.refusal).to eq(described_class::NOT_ENABLED)
    end
  end

  context "in production with enabled = true" do
    before { in_environment("production") }

    it "the runner raises before opening any connection" do
      expect(Profiler::ExplainRunner).not_to receive(:open_probe_connection)

      expect { Profiler::ExplainRunner.run(store_select, 0) }
        .to raise_error(SecurityError, /only available in the development and test environments/)
    end

    it "the endpoint answers 403 and runs nothing" do
      expect(Profiler::ExplainRunner).not_to receive(:open_probe_connection)

      post "/_profiler/api/explain", { token: store_select, query_index: 0 }, writing

      expect(last_response.status).to eq(403)
      expect(json["error"]).to eq(Profiler::ExplainRunner::OUTSIDE_DEVELOPMENT)
    end

    it "the MCP tool answers an error and runs nothing" do
      expect(Profiler::ExplainRunner).not_to receive(:open_probe_connection)

      text = Profiler::MCP::Tools::ExplainQuery.call("token" => store_select, "query_index" => 0).content.first[:text]

      expect(text).to eq("Error: #{Profiler::ExplainRunner::OUTSIDE_DEVELOPMENT}")
    end

    it "explains with config.allow_explain_outside_development = true" do
      Profiler.configuration.allow_explain_outside_development = true

      post "/_profiler/api/explain", { token: store_select, query_index: 0 }, writing

      expect(last_response.status).to eq(200)
      expect(json).to include("adapter" => "sqlite")
    end
  end

  it "the MCP description of explain_query says what the gate is" do
    require "profiler/mcp/server"
    tool = Profiler::MCP::Server.new.send(:build_tools).find { |t| t.name_value == "explain_query" }
    description = tool.description_value

    expect(description).to include("development or test environment")
    expect(description).to include("config.allow_explain_outside_development")
    expect(description).not_to include("Only available in development/test environments")
  end
end
