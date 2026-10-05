# frozen_string_literal: true

require "spec_helper"
require "action_controller"

# ProfilerMiddleware#buffered_rails_body? reads Rails' internals to tell a page held in memory
# from a stream when the body has no to_ary. This fails, rather than the toolbar silently
# disappearing, if a Rails release changes them.
RSpec.describe "Rails response body internals the profiler reads" do
  it "keeps the response of a RackBody in @response" do
    response = ActionDispatch::Response.new
    body = ActionDispatch::Response::RackBody.new(response)
    expect(body.instance_variable_get(:@response)).to equal(response)
  end

  it "has a Response::Buffer that says whether it is closed" do
    stream = ActionDispatch::Response.new.stream
    expect(stream).to be_an_instance_of(ActionDispatch::Response::Buffer)
    expect(stream).to respond_to(:closed?)
  end

  # Whether a Live action's buffer is closed when the application returns is checked with a
  # real controller in profiler_middleware_live_spec.rb.
  it "has a Live::Buffer, distinct from Response::Buffer, that says whether it is closed" do
    stream = ActionController::Live::Response.new.stream
    expect(stream).to be_an_instance_of(ActionController::Live::Buffer)
    expect(stream).not_to be_an_instance_of(ActionDispatch::Response::Buffer)
    expect(stream.closed?).to be(false)
  end
end
