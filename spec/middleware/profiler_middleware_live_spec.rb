# frozen_string_literal: true

require "spec_helper"
require "rack"
require "action_controller"

# A controller that includes ActionController::Live answers every action through a
# Live::Buffer: a page it renders whole is still a page, a stream is still a stream.
RSpec.describe Profiler::Middleware::ProfilerMiddleware, "with ActionController::Live" do
  class LiveProbeController < ActionController::Base
    include ActionController::Live

    PAGE = "<html><body>hello</body></html>"

    def page
      render html: PAGE.html_safe
    end

    def stream
      response.headers["Content-Type"] = "text/plain"
      3.times do |i|
        sleep 0.15
        response.stream.write("chunk#{i}")
      end
    ensure
      response.stream.close
    end
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = []
      c.skip_paths = []
      c.track_memory = false
      c.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def call(action)
    env = Rack::MockRequest.env_for("http://localhost/#{action}", "REMOTE_ADDR" => "127.0.0.1")
    described_class.new(LiveProbeController.action(action)).call(env)
  end

  def serve(body)
    parts = []
    body.each { |part| parts << part }
    parts.join
  ensure
    body.close if body.respond_to?(:close)
  end

  it "injects the toolbar into a page the action rendered whole" do
    _status, headers, body = call(:page)
    page = serve(body)

    expect(page).to include("profiler-toolbar")
    length = headers["content-length"]
    expect(length.nil? || length == page.bytesize.to_s).to be(true)
  end

  it "still streams an action that writes to the stream" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _status, _headers, body = call(:stream)
    returned_after = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(body).not_to respond_to(:to_ary)
    expect(serve(body)).to eq("chunk0chunk1chunk2")
    expect(returned_after).to be < 0.4
  end
end
