# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require_relative "../support/rails_app"

RSpec.describe "Test runner file selection", type: :request do
  include Rack::Test::Methods

  let(:local) { { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" } }
  let(:profiler_header) { { "HTTP_X_PROFILER_REQUEST" => "1" } }
  let(:root) { Rails.root.to_s }

  def app
    Rails.application
  end

  def json
    JSON.parse(last_response.body)
  end

  def start_run(files, framework: "rspec")
    post "/_profiler/api/test_runner/runs", { files: files, framework: framework }, local.merge(profiler_header)
  end

  def write(relative, content = "")
    path = File.join(root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = []
      config.track_http = false
      config.authorization_mode = :allow_local
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)

    write("spec/models/user_spec.rb")
    write("spec/models/post_spec.rb")
    write("lib/tasks/not_a_test.rb")
  end

  after do
    FileUtils.rm_rf(File.join(root, "spec"))
    FileUtils.rm_rf(File.join(root, "lib"))
    Profiler::TestRunner.instance_variable_set(:@run_store, nil)
  end

  describe "a file that is not a discovered test" do
    it "is refused with a 422 and no process is started" do
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)

      start_run(["lib/tasks/not_a_test.rb"])

      expect(last_response.status).to eq(422)
      expect(json["error"]).to include("lib/tasks/not_a_test.rb")
    end

    it "is refused even when listed next to a discovered test" do
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)

      start_run(["spec/models/user_spec.rb", "lib/tasks/not_a_test.rb"])

      expect(last_response.status).to eq(422)
    end

    it "is refused through a symbolic link placed in the spec directory" do
      File.symlink(File.join(root, "lib/tasks/not_a_test.rb"), File.join(root, "spec/models/helper_link.rb"))
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)

      start_run(["spec/models/helper_link.rb"])

      expect(last_response.status).to eq(422)
    end

    it "is refused with a 422 when the path holds a null byte" do
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)

      start_run(["spec/models/user_spec.rb\0"])

      expect(last_response.status).to eq(422)
    end

    it "is refused with a 422 when sent for the other framework" do
      write("test/models/user_test.rb")
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)

      start_run(["test/models/user_test.rb"], framework: "rspec")

      expect(last_response.status).to eq(422)
    ensure
      FileUtils.rm_rf(File.join(root, "test"))
    end

    it "is refused when the path leaves the Rails root" do
      expect(Profiler::TestRunner::Runner).not_to receive(:spawn_async)

      start_run(["../outside_spec.rb"])

      expect(last_response.status).to eq(422)
    end
  end

  describe "a discovered test file" do
    before { allow(Profiler::TestRunner::Runner).to receive(:spawn_async) }

    it "is accepted and started" do
      start_run(["spec/models/user_spec.rb"])

      expect(last_response.status).to eq(201)
      expect(json["files"]).to eq(["spec/models/user_spec.rb"])
      expect(Profiler::TestRunner::Runner).to have_received(:spawn_async).once
    end

    it "is accepted with several files" do
      start_run(["spec/models/user_spec.rb", "spec/models/post_spec.rb"])

      expect(last_response.status).to eq(201)
      expect(json["files"]).to eq(["spec/models/user_spec.rb", "spec/models/post_spec.rb"])
    end

    it "is accepted with a line number" do
      start_run(["spec/models/user_spec.rb:12"])

      expect(last_response.status).to eq(201)
      expect(json["files"]).to eq(["spec/models/user_spec.rb:12"])
    end
  end

  # spawn_async is stubbed: the runs started here keep their place until the end of the example.
  describe "past config.test_runner_max_active_runs" do
    before do
      allow(Profiler::TestRunner::Runner).to receive(:spawn_async)
      Profiler.configuration.test_runner_max_active_runs = 1
    end

    it "is refused with a 429 naming the limit, and nothing is started" do
      start_run(["spec/models/user_spec.rb"])
      expect(last_response.status).to eq(201)

      start_run(["spec/models/post_spec.rb"])

      expect(last_response.status).to eq(429)
      expect(json["error"]).to include("test_runner_max_active_runs")
      expect(Profiler::TestRunner::Runner).to have_received(:spawn_async).once
      expect(Profiler::TestRunner.run_store.all.size).to eq(1)
    end
  end

  describe "a run this process does not know" do
    it "answers 404 naming the server processes as a possible cause" do
      get "/_profiler/api/test_runner/runs/0123456789abcdef", {}, local.merge(profiler_header)

      expect(last_response.status).to eq(404)
      expect(json["error"]).to start_with("Run not found")
      expect(json["error"]).to include("process")
    end
  end
end
