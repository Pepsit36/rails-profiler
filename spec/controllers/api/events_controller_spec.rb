# frozen_string_literal: true

# EventsController requires a full Rails controller harness (ActionController::Live,
# ActionDispatch routing) that is not available in this project's pure-unit spec_helper.
# To test the content-type header and SSE streaming behaviour, a Combustion/spec-dummy
# app is needed so that a real Rack request can be issued and the response headers read.
#
# Example of what the spec would assert once that harness exists:
#
#   before do
#     allow_any_instance_of(Profiler::SSE::EventBus)
#       .to receive(:subscribe).and_return("stub-id")
#     allow_any_instance_of(Profiler::SSE::EventBus)
#       .to receive(:unsubscribe)
#     call_count = 0
#     allow_any_instance_of(Profiler::SSE::EventBus)
#       .to receive(:wait_for_event) do
#         call_count += 1
#         call_count == 1 ? { token: "tok", collectors: [], timestamp: Time.now.to_f }
#                         : raise(IOError, "simulated disconnect")
#       end
#   end
#
#   it "responds with text/event-stream" do
#     get "/_profiler/api/events/tok"
#     expect(response.content_type).to include("text/event-stream")
#   end

RSpec.describe "Profiler::Api::EventsController" do
  it "is pending: requires a Rails controller harness not present in spec_helper" do
    pending "no ActionController/ActionDispatch harness in spec_helper — " \
            "add Combustion or spec/dummy app to enable controller specs"
    raise
  end
end
