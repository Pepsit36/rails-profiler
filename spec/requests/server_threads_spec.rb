# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require_relative "../support/puma_app_server"

# What the profiler's own endpoints hold a server thread for, measured on a real Puma with as
# many threads as there are open browser tabs: whatever the tabs do, the application has to
# keep answering. A free server answers in a few milliseconds and a blocked one not at all, so
# the margins are wide: blocked means no answer after `blocked` seconds, free means an answer
# within `free` seconds.
RSpec.describe "Server threads held by the profiler's endpoints" do
  def threads = 3
  # Long enough for Puma to hand every opened connection to a thread.
  def settle = 1
  def blocked = 5
  def free = 1

  attr_reader :server

  around do |example|
    @server = PumaAppServer.new(threads: threads)
    begin
      server.start
      example.run
    ensure
      server.stop
    end
  end

  def open_connections(path)
    sockets = Array.new(threads) { server.open_connection(path) }
    sleep settle
    sockets
  end

  def expect_application_to_answer
    expect(server.time_request("/hello", limit: blocked)).to be < free
  end

  it "answers the application while one toolbar per thread watches its profile" do
    sockets = open_connections("/_profiler/api/events/tok")

    expect_application_to_answer
    expect(server.read_head(sockets.first, limit: blocked)).to match(%r{\AHTTP/1.1 200 .*^content-type: application/json}im)
  end

  it "answers the application right after the toolbars that watched went away" do
    open_connections("/_profiler/api/events/tok").each(&:close)

    expect_application_to_answer
  end

  it "answers the application while one test runner page per thread follows a run in progress" do
    sockets = open_connections("/_profiler/api/test_runner/runs/#{server.run_id}/stream")

    expect_application_to_answer
    expect(server.read_head(sockets.first, limit: blocked)).to match(%r{\AHTTP/1.1 200 .*^content-type: text/event-stream}im)
  end

  it "answers the application right after the test runner pages that followed a run went away" do
    open_connections("/_profiler/api/test_runner/runs/#{server.run_id}/stream").each(&:close)

    expect_application_to_answer
  end

  # A CI job that times out kills rspec with SIGKILL: no ensure runs, and the Puma child must not
  # stay behind, listening.
  describe "the Puma child of a spec process that is killed" do
    after do
      begin
        Process.kill("KILL", @orphan) if @orphan
      rescue Errno::ESRCH
        nil
      end
      # The killed parent could not delete its child's error output.
      FileUtils.rm_f(Dir.glob(File.join(Dir.tmpdir, "profiler-puma-app-server-#{@parent}-*.log"))) if @parent
    end

    def listening?(port)
      TCPSocket.new("127.0.0.1", port).close
      true
    rescue SystemCallError
      false
    end

    it "stops listening" do
      support = File.expand_path("../support/puma_app_server", __dir__)
      script = "require #{support.inspect}; server = PumaAppServer.new(threads: 1).start; " \
               "puts server.port, server.pid; $stdout.flush; sleep"
      reader, writer = IO.pipe
      parent = @parent = Process.spawn(RbConfig.ruby, "-e", script, out: writer, err: File::NULL)
      writer.close
      port = Integer(reader.gets)
      @orphan = Integer(reader.gets)
      reader.close
      expect(listening?(port)).to be(true)

      Process.kill("KILL", parent)
      Process.wait(parent)

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + blocked
      sleep 0.1 while listening?(port) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      expect(listening?(port)).to be(false)
    end
  end
end
