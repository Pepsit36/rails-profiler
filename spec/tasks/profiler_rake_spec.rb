# frozen_string_literal: true

require "spec_helper"
require "rake"

RSpec.describe "profiler rake tasks" do
  let(:storage) { instance_double(Profiler::Storage::MemoryStore, cleanup: nil, list: []) }

  before do
    @previous_rake = Rake.application
    Rake.application = Rake::Application.new
    Rake::Task.define_task(:environment)
    load File.expand_path("../../lib/profiler/tasks/profiler.rake", __dir__)
    allow(Profiler).to receive(:storage).and_return(storage)
    @saved_env = ENV.to_h.slice("OLDER_THAN", "LIMIT", "MCP_TRANSPORT")
    ENV.delete("OLDER_THAN")
    ENV.delete("LIMIT")
    ENV.delete("MCP_TRANSPORT")
  end

  after do
    ENV.delete("OLDER_THAN")
    ENV.delete("LIMIT")
    ENV.delete("MCP_TRANSPORT")
    ENV.update(@saved_env)
    Rake.application = @previous_rake
  end

  def run_task(name)
    task = Rake::Task[name]
    task.reenable
    task.invoke
  end

  describe "profiler:cleanup" do
    it "removes the profiles older than a day when OLDER_THAN is not set" do
      expect { run_task("profiler:cleanup") }.to output(/86400 seconds/).to_stdout
      expect(storage).to have_received(:cleanup).with(older_than: 86_400)
    end

    it "passes OLDER_THAN, in seconds, to the store" do
      ENV["OLDER_THAN"] = "3600"
      expect { run_task("profiler:cleanup") }.to output.to_stdout
      expect(storage).to have_received(:cleanup).with(older_than: 3600)
    end

    it "accepts 0, to remove every profile on purpose" do
      ENV["OLDER_THAN"] = "0"
      expect { run_task("profiler:cleanup") }.to output.to_stdout
      expect(storage).to have_received(:cleanup).with(older_than: 0)
    end

    ["", "abc", "1h", "-5", "1.5"].each do |value|
      it "stops, removing nothing, when OLDER_THAN is #{value.inspect}" do
        ENV["OLDER_THAN"] = value
        expect { run_task("profiler:cleanup") }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/OLDER_THAN must be a whole number of seconds.*#{Regexp.escape(value.inspect)}/).to_stderr
        expect(storage).not_to have_received(:cleanup)
      end
    end
  end

  describe "profiler:list" do
    it "lists 20 profiles when LIMIT is not set" do
      expect { run_task("profiler:list") }.to output(/No profiles found/).to_stdout
      expect(storage).to have_received(:list).with(limit: 20)
    end

    it "passes LIMIT to the store" do
      ENV["LIMIT"] = "5"
      expect { run_task("profiler:list") }.to output.to_stdout
      expect(storage).to have_received(:list).with(limit: 5)
    end

    ["", "abc", "0", "10x"].each do |value|
      it "stops when LIMIT is #{value.inspect}" do
        ENV["LIMIT"] = value
        expect { run_task("profiler:list") }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
          .and output(/LIMIT must be a whole number of profiles/).to_stderr
        expect(storage).not_to have_received(:list)
      end
    end
  end

  describe "profiler:mcp" do
    it "starts the MCP server with :stdio transport by default" do
      server_double = instance_double(Profiler::MCP::Server, start: nil)
      allow(Profiler::MCP::Server).to receive(:new).and_return(server_double)

      expect { run_task("profiler:mcp") }.to output(/stdio transport/).to_stderr
      expect(server_double).to have_received(:start).with(transport: :stdio)
    end

    it "uses MCP_TRANSPORT environment variable to override the default" do
      server_double = instance_double(Profiler::MCP::Server, start: nil)
      allow(Profiler::MCP::Server).to receive(:new).and_return(server_double)
      ENV["MCP_TRANSPORT"] = "http"

      expect { run_task("profiler:mcp") }.to output(/http transport/).to_stderr
      expect(server_double).to have_received(:start).with(transport: :http)
    end
  end
end
