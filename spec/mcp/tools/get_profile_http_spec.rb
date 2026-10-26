# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "support/mcp_tool_schema"
require "profiler/mcp/file_cache"
require "profiler/mcp/path_extractor"
require "profiler/mcp/body_formatter"
require "profiler/mcp/tools/get_profile_http"

RSpec.describe Profiler::MCP::Tools::GetProfileHttp do
  let(:store) { Profiler::Storage::MemoryStore.new }
  let(:tmp_dir) { Dir.mktmpdir }

  before do
    Profiler.configure { |c| c.tmp_path = Pathname.new(tmp_dir) }
    Profiler.instance_variable_set(:@storage, store)
  end

  after do
    Profiler.instance_variable_set(:@storage, nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def request(attrs = {})
    {
      "id" => "req-1", "started_at" => "2026-10-15T10:00:00Z", "method" => "POST",
      "url" => "https://api.example.com/v1/charges", "status" => 201, "duration" => 120.456,
      "request_size" => 12, "response_size" => 34,
      "request_headers" => { "Content-Type" => "application/json", "User-Agent" => "Ruby" },
      "request_body" => '{"amount":1}', "response_headers" => { "X-Id" => "abc" },
      "response_body" => '{"data":{"id":"ch_1"}}', "backtrace" => %w[app/a.rb:1 app/b.rb:2 app/c.rb:3 app/d.rb:4]
    }.merge(attrs)
  end

  def save(requests, extra = {})
    http = {
      "total_requests" => requests.size, "total_duration" => 1234.5678, "slow_requests" => 1, "error_requests" => 1,
      "by_host" => { "api.example.com" => 2 }, "by_status" => { "201" => 1, "0" => 1 }, "requests" => requests
    }.merge(extra)
    build_profile(method: "GET", path: "/checkout", collectors_data: { "http" => http }).tap { |p| store.save(p.token, p) }
  end

  def text(params)
    described_class.call(params).first[:text]
  end

  it "requires a token, with optional body and domain options" do
    schema = mcp_tool_schema("get_profile_http")

    expect(schema[:properties].transform_values { |p| p[:type] }).to eq(
      token: "string", domain: "string", save_bodies: "boolean", max_body_size: "number",
      json_path: "string", xml_path: "string", slave: "string"
    )
    expect(schema[:required]).to eq(["token"])
  end

  it "asks for the token when it is missing" do
    expect(text({})).to eq("Error: token parameter is required")
  end

  it "says so when the profile does not exist" do
    expect(text("token" => "a" * 32)).to eq("Profile not found: #{'a' * 32}")
  end

  it "says so when the profile made no outbound request" do
    profile = build_profile.tap { |p| store.save(p.token, p) }
    empty = save([], "total_requests" => 0)

    expect(text("token" => profile.token)).to eq("No outbound HTTP requests found in this profile")
    expect(text("token" => empty.token)).to eq("No outbound HTTP requests found in this profile")
  end

  it "describes every outbound request of the profile" do
    failed = request("id" => nil, "started_at" => nil, "method" => "GET", "url" => "https://down.example.org/ping",
                     "status" => 0, "duration" => 600, "request_size" => nil, "error" => "Errno::ECONNREFUSED",
                     "request_headers" => {}, "request_body" => nil, "response_headers" => {}, "response_body" => nil,
                     "backtrace" => nil, "request_body_not_captured" => true, "request_body_truncated" => true,
                     "response_body_truncated" => true)
    profile = save([request("request_size_is_minimum" => true), failed])

    output = text("token" => profile.token)

    expect(output).to include(
      "# Outbound HTTP Analysis: #{profile.token}\n",
      "**Request:** GET /checkout",
      "**Total Outbound Requests:** 2",
      "**Showing:** 2 request(s)\n",
      "**Total Duration:** 1234.57 ms",
      "**Slow Requests (>500ms):** 1",
      "## By Host\n- **api.example.com**: 2",
      "## By Status\n- **201**: 1\n- **0**: 1"
    )
    expect(output).to include(<<~MD.chomp)
      ### Request 1
      - **ID:** req-1
      - **Started at:** 2026-10-15T10:00:00Z
      - **Method:** POST
      - **URL:** https://api.example.com/v1/charges
      - **Status:** 201
      - **Duration:** 120.46 ms
      - **Request Size:** at least 12 bytes
      - **Response Size:** 34 bytes
      - **Request Headers:**
        - `Content-Type`: application/json
        - `User-Agent`: Ruby
      - **Request Body:**
      ```
      {"amount":1}
      ```
      - **Response Headers:**
        - `X-Id`: abc
      - **Response Body:**
      ```
      {"data":{"id":"ch_1"}}
      ```
      - **Called from:**
        - app/a.rb:1
        - app/b.rb:2
        - app/c.rb:3
      - **Curl:**
        ```bash
        curl -X POST \\
        -H Content-Type:\\ application/json \\
        -d \\{\\"amount\\":1\\} \\
        https://api.example.com/v1/charges
        ```
    MD
    expect(output).to include(
      "### Request 2 [SLOW] [ERROR]",
      "- **Status:** connection error",
      "- **Request Size:** unknown",
      "- _Request body not captured: a stream that cannot be rewound is sent unread._",
      "- _Request body truncated: only the first bytes were kept (max_captured_body_bytes)._",
      "- _Response body truncated: only the first bytes were kept (max_captured_body_bytes)._",
      "- **Error:** Errno::ECONNREFUSED"
    )
    expect(output).not_to include("app/d.rb:4")
  end

  it "reads the most recent profile for the latest token" do
    save([request("url" => "https://older.example.com/")])
    save([request("url" => "https://newer.example.com/")])

    expect(text("token" => "latest")).to include("https://newer.example.com/")
  end

  it "handles in-flight requests with nil duration" do
    in_flight = request("method" => "GET", "url" => "https://api.example.com/pending", "status" => nil, "duration" => nil)
    profile = save([in_flight])

    output = text("token" => profile.token)

    expect(output).to include("### Request 1 [ERROR]")
    expect(output).to include("- **Status:** connection error")
    expect(output).to include("- **Duration:** 0.0 ms")
  end

  it "keeps only the requests whose host matches the domain filter, without the breakdowns" do
    profile = save([request, request("url" => "https://other.example.net/x"), request("url" => "http://[bad")])

    output = text("token" => profile.token, "domain" => "example.net")

    expect(output).to include("**Showing:** 1 request(s) (filtered by domain: example.net)")
    expect(output).to include("https://other.example.net/x")
    expect(output).not_to include("api.example.com/v1/charges", "## By Host", "## By Status")
  end

  it "leaves a base64 body out of the body and the curl command" do
    profile = save([request("request_body" => "AAEC", "request_body_encoding" => "base64")])

    output = text("token" => profile.token)

    expect(output).to include("- **Request Body:**\n  *(binary, base64 encoded)*")
    expect(output).not_to include("-d ")
  end

  it "truncates an inlined body at max_body_size" do
    profile = save([request("response_body" => "x" * 30)])

    expect(text("token" => profile.token, "max_body_size" => 10))
      .to include("```\nxxxxxxxxxx\n... [truncated, 30 chars total]\n```")
  end

  it "saves the bodies to files and extracts the json_path when asked" do
    profile = save([request])

    output = text("token" => profile.token, "save_bodies" => true, "json_path" => "$.data.id")

    saved = output.scan(/saved → `([^`]+)`/).flatten
    expect(saved.size).to eq(2)
    expect(File.read(saved.last)).to eq('{"data":{"id":"ch_1"}}')
    expect(output).to include("`$.data.id` → `\"ch_1\"`")
  end

  it "reads the profile of a slave" do
    require "profiler/cluster/slave_proxy"
    proxy = instance_double(Profiler::Cluster::SlaveProxy)
    remote = save([request("url" => "https://remote.example.com/")])
    allow(Profiler::MCP::SlaveSupport).to receive(:resolve_storage).and_return(proxy)
    expect(proxy).to receive(:load).with(remote.token).and_return(remote)

    expect(text("token" => remote.token, "slave" => "payment")).to include("https://remote.example.com/")
  end
end
