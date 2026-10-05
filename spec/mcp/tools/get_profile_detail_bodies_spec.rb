# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/request_collector"
require "profiler/mcp/body_formatter"
require "profiler/mcp/tools/get_profile_detail"

# PERF-05: the bodies are stored gzip+base64 past compress_body_threshold; the MCP detail shows
# them as text, and the curl command carries the request body as sent, not its stored form.
RSpec.describe Profiler::MCP::Tools::GetProfileDetail do
  before do
    Profiler.configure { |c| c.storage = :memory }
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
  end

  def store_profile(request_body:, req_content_type:)
    profile = Profiler::Models::Profile.new
    profile.path = "/orders"
    profile.method = "POST"
    profile.set_bodies(request_body: request_body, response_body: "<p>#{"done " * 4000}</p>",
                       req_content_type: req_content_type, resp_content_type: "text/html")
    profile.finish(200, {})
    Profiler::Collectors::RequestCollector.new(profile).collect
    Profiler.storage.save(profile.token, profile)
    profile
  end

  def detail(profile, sections)
    described_class.call("token" => profile.token, "sections" => sections).first[:text]
  end

  let(:large_body) { "order=#{"x" * 12_000}&end=1" }

  it "puts a compressed request body in the curl command as text" do
    profile = store_profile(request_body: large_body, req_content_type: "text/plain")
    expect(profile.request_body_encoding).to eq("gzip+base64")

    curl = detail(profile, ["curl"])
    expect(curl).to include("-d #{Shellwords.shellescape(large_body)}")
    expect(curl).not_to include(profile.request_body)
  end

  it "leaves a binary request body out of the curl command" do
    profile = store_profile(request_body: "\x89PNG\r\n".b * 10, req_content_type: "image/png")
    expect(profile.request_body_encoding).to eq("base64")

    expect(detail(profile, ["curl"])).not_to include(profile.request_body)
  end

  it "shows the compressed request and response bodies as text" do
    profile = store_profile(request_body: large_body, req_content_type: "text/plain")

    text = detail(profile, %w[request response])
    expect(text).to include("order=xxxx")
    expect(text).to include("done done")
    expect(text).not_to include(profile.response_body)
  end
end
