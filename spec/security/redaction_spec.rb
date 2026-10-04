# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "socket"
require "tmpdir"
require "profiler/instrumentation/net_http_instrumentation"
require "profiler/collectors/env_collector"
require "profiler/collectors/request_collector"
require "profiler/collectors/database_collector"
require "profiler/collectors/mailer_collector"
require "profiler/mcp/tools/list_env_vars"

# Regression specs for SEC-03: sensitive data captured by the profiler must be
# masked before it is stored, using the host application's
# config.filter_parameters as the single source of truth.
RSpec.describe "Sensitive data redaction" do
  include Rack::Test::Methods

  MASK = "[FILTERED]"

  # Every value below is planted somewhere in a request and must never reach
  # the stored profile.
  PLANTED = {
    root_param: "planted-api-key-1111",
    nested_param: "planted-nested-password-2222",
    upcase_param: "planted-upcase-password-3333",
    regex_param: "planted-regex-token-4444",
    json_body: "planted-json-password-5555",
    form_body: "planted-form-password-6666",
    authorization: "Bearer planted-authorization-7777",
    cookie: "_session=planted-cookie-8888",
    set_cookie: "_session=planted-set-cookie-9999; path=/; HttpOnly",
    response_json: "planted-response-token-0000",
    outbound_authorization: "Bearer planted-outbound-authorization-aaaa",
    outbound_body: "planted-outbound-secret-bbbb",
    outbound_query: "planted-outbound-query-key-cccc",
    outbound_set_cookie: "sid=planted-outbound-set-cookie-dddd",
    env: "planted-env-value-eeee"
  }.freeze

  let(:rails_filters) { [:password, :api_key, :secret, /token/i] }

  before do
    stub_const("Rails", fake_rails(rails_filters))
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = []
      c.skip_paths = []
      c.track_memory = false
      c.track_http = true
    end
  end

  # A minimal stand-in for the Rails module: just enough for the profiler to
  # read config.filter_parameters, and nothing that looks like a real app.
  def fake_rails(filters)
    config = Struct.new(:filter_parameters).new(filters)
    app = Struct.new(:config).new(config)
    Struct.new(:application, :logger).new(app, nil)
  end

  def rack_env(path, method: "POST", body: "", content_type: nil, headers: {})
    opts = { method: method, input: body }
    opts["CONTENT_TYPE"] = content_type if content_type
    headers.each { |k, v| opts["HTTP_#{k.upcase.tr('-', '_')}"] = v }
    Rack::MockRequest.env_for(path, opts)
  end

  describe "request parameters" do
    let(:profile) do
      env = rack_env(
        "/login?api_key=#{PLANTED[:root_param]}&PASSWORD=#{PLANTED[:upcase_param]}" \
        "&user[password]=#{PLANTED[:nested_param]}&access_token=#{PLANTED[:regex_param]}&page=2",
        method: "GET"
      )
      Profiler::Models::Profile.new(Rack::Request.new(env))
    end

    it "masks a root parameter listed in filter_parameters" do
      expect(profile.params["api_key"]).to eq(MASK)
    end

    it "masks a nested parameter" do
      expect(profile.params["user"]["password"]).to eq(MASK)
    end

    it "masks a parameter whose name differs only by case" do
      expect(profile.params["PASSWORD"]).to eq(MASK)
    end

    it "masks a parameter matched by a regexp filter" do
      expect(profile.params["access_token"]).to eq(MASK)
    end

    it "keeps parameters that match no filter" do
      expect(profile.params["page"]).to eq("2")
    end
  end

  describe "incoming headers" do
    let(:profile) do
      env = rack_env("/", method: "GET", headers: {
        "Authorization" => PLANTED[:authorization], "Cookie" => PLANTED[:cookie], "Accept" => "text/html"
      })
      Profiler::Models::Profile.new(Rack::Request.new(env))
    end

    it "masks Authorization and Cookie but keeps other headers" do
      expect(profile.headers["Authorization"]).to eq(MASK)
      expect(profile.headers["Cookie"]).to eq(MASK)
      expect(profile.headers["Accept"]).to eq("text/html")
    end

    it "masks Set-Cookie and filtered names in response headers" do
      profile.finish(200, { "Set-Cookie" => PLANTED[:set_cookie], "X-Auth-Token" => "abc",
                            "Content-Type" => "text/html" })
      expect(profile.response_headers["Set-Cookie"]).to eq(MASK)
      expect(profile.response_headers["X-Auth-Token"]).to eq(MASK)
      expect(profile.response_headers["Content-Type"]).to eq("text/html")
    end
  end

  describe "request and response bodies" do
    let(:profile) { Profiler::Models::Profile.new }

    it "masks filtered keys in a JSON body, nested included" do
      body = JSON.generate(user: { email: "a@b.c", password: PLANTED[:json_body] })
      profile.set_bodies(request_body: body, response_body: JSON.generate(access_token: PLANTED[:response_json]),
                         req_content_type: "application/json", resp_content_type: "application/json; charset=utf-8")

      expect(JSON.parse(profile.request_body)).to eq("user" => { "email" => "a@b.c", "password" => MASK })
      expect(JSON.parse(profile.response_body)).to eq("access_token" => MASK)
    end

    it "masks filtered keys in a form-urlencoded body" do
      body = "user%5Bemail%5D=a%40b.c&user%5Bpassword%5D=#{PLANTED[:form_body]}&PASSWORD=x"
      profile.set_bodies(request_body: body, response_body: "",
                         req_content_type: "application/x-www-form-urlencoded", resp_content_type: "")

      expect(profile.request_body).to eq("user%5Bemail%5D=a%40b.c&user%5Bpassword%5D=#{MASK}&PASSWORD=#{MASK}")
    end

    it "masks a body that cannot be parsed as its declared JSON type" do
      body = "{\"password\": \"#{PLANTED[:json_body]}\""
      profile.set_bodies(request_body: body, response_body: "",
                         req_content_type: "application/json", resp_content_type: "")

      expect(profile.request_body).not_to include(PLANTED[:json_body])
    end

    it "masks a multipart body entirely" do
      body = "--b\r\nContent-Disposition: form-data; name=\"password\"\r\n\r\n#{PLANTED[:form_body]}\r\n--b--\r\n"
      profile.set_bodies(request_body: body, response_body: "",
                         req_content_type: "multipart/form-data; boundary=b", resp_content_type: "")

      expect(profile.request_body).not_to include(PLANTED[:form_body])
    end
  end

  describe "outbound HTTP (Net::HTTP instrumentation)" do
    let(:collector) { Profiler::Collectors::HttpCollector.new(build_profile) }

    around do |example|
      server = TCPServer.new("127.0.0.1", 0)
      @port = server.addr[1]
      thread = Thread.new do
        client = server.accept
        while (line = client.gets) && line != "\r\n"; end
        length = 0
        client.read(length)
        body = JSON.generate(token: "server-token", ok: true)
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Set-Cookie: #{PLANTED[:outbound_set_cookie]}\r\n" \
                     "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
        client.close
      end
      example.run
    ensure
      thread&.join(2)
      server&.close
    end

    it "masks sensitive outbound headers, body keys and query parameters" do
      allow(Profiler::Instrumentation::NetHttpInstrumentation).to receive(:skip_host?).and_return(false)
      collector.subscribe

      http = Net::HTTP.new("127.0.0.1", @port)
      req = Net::HTTP::Post.new("/v1/charge?api_key=#{PLANTED[:outbound_query]}&page=1")
      req["Authorization"] = PLANTED[:outbound_authorization]
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(amount: 10, secret: PLANTED[:outbound_body])
      http.request(req)

      collector.collect
      entry = collector.panel_content[:requests].first

      expect(entry["request_headers"]["authorization"]).to eq(MASK)
      expect(entry["response_headers"]["set-cookie"]).to eq(MASK)
      expect(JSON.parse(entry["request_body"])).to eq("amount" => 10, "secret" => MASK)
      expect(JSON.parse(entry["response_body"])).to eq("token" => MASK, "ok" => true)
      expect(entry["url"]).to eq("http://127.0.0.1:#{@port}/v1/charge?api_key=#{MASK}&page=1")
    end
  end

  describe "environment variables" do
    around do |example|
      ENV["PROFILER_SPEC_UNLISTED_VAR"] = PLANTED[:env]
      ENV["RAILS_ENV"], previous = "test", ENV["RAILS_ENV"]
      example.run
    ensure
      ENV.delete("PROFILER_SPEC_UNLISTED_VAR")
      ENV["RAILS_ENV"] = previous
    end

    it "masks variables outside the allowlist in the Env collector" do
      profile = build_profile
      Profiler::Collectors::EnvCollector.new(profile).collect
      variables = profile.collector_data("env")[:variables]

      expect(variables["PROFILER_SPEC_UNLISTED_VAR"]).to eq(MASK)
      expect(variables["RAILS_ENV"]).to eq("test")
    end

    it "applies the same rule to the list_env_vars MCP tool" do
      text = Profiler::MCP::Tools::ListEnvVars.call("include_all" => true).first[:text]

      expect(text).not_to include(PLANTED[:env])
      expect(text).to include("| RAILS_ENV | test |")
    end
  end

  describe "other capture points" do
    it "masks SQL bind values whose column name matches the filter" do
      profile = build_profile
      collector = Profiler::Collectors::DatabaseCollector.new(profile)
      collector.subscribe
      bind = Struct.new(:name, :value)
      ActiveSupport::Notifications.instrument("sql.active_record",
        sql: "UPDATE users SET encrypted_password = ?, name = ?", name: "User Update",
        binds: [bind.new("password_digest", PLANTED[:nested_param]), bind.new("name", "Alice")])
      collector.collect

      expect(profile.collector_data("database")[:queries].first[:binds]).to eq([MASK, "Alice"])
    end

    it "masks filtered keys in job arguments" do
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      Profiler::JobProfiler.profile(job_class: "SignupJob", job_id: "j1", queue: "default",
                                    arguments: [{ "email" => "a@b.c", "password" => PLANTED[:nested_param] }],
                                    executions: 0) {}
      stored = Profiler.storage.list.first

      expect(stored.to_json).not_to include(PLANTED[:nested_param])
    end

    it "masks filtered mailer arguments in assigns" do
      stub_const("ResetMailer", Class.new { def reset(user_id, reset_token); end })
      Profiler.configure { |c| c.track_mailers = true }
      profile = build_profile
      collector = Profiler::Collectors::MailerCollector.new(profile)
      collector.subscribe
      ActiveSupport::Notifications.instrument("process.action_mailer",
        mailer: "ResetMailer", action: "reset", args: [42, PLANTED[:regex_param]])
      ActiveSupport::Notifications.instrument("deliver.action_mailer",
        mailer_class: "ResetMailer", subject: "Reset", to: ["a@b.c"], from: ["n@b.c"],
        message_id: "<m@b.c>", perform_deliveries: true, mail: nil)
      collector.collect
      assigns = profile.collector_data("mailer")[:emails].first["assigns"]

      expect(assigns).to eq("user_id" => "42", "reset_token" => MASK)
    end
  end

  describe "the stored profile, end to end" do
    let(:dir) { Dir.mktmpdir }
    after { FileUtils.rm_rf(dir) }

    # rack-test sends REMOTE_ADDR 127.0.0.1: a browser on this machine, as :allow_local expects.
    def default_host
      "localhost"
    end

    def app
      inner = lambda do |_env|
        [200, { "Content-Type" => "application/json", "Set-Cookie" => PLANTED[:set_cookie] },
         [JSON.generate(access_token: PLANTED[:response_json])]]
      end
      Profiler::Middleware::ProfilerMiddleware.new(inner)
    end

    it "contains none of the planted sensitive values" do
      ENV["PROFILER_SPEC_UNLISTED_VAR"] = PLANTED[:env]
      Profiler.configure do |c|
        c.collectors = [Profiler::Collectors::RequestCollector, Profiler::Collectors::EnvCollector]
      end
      Profiler.instance_variable_set(:@storage, Profiler::Storage::FileStore.new(path: dir))

      header "Authorization", PLANTED[:authorization]
      header "Cookie", PLANTED[:cookie]
      post "/login?api_key=#{PLANTED[:root_param]}&access_token=#{PLANTED[:regex_param]}",
           JSON.generate(user: { password: PLANTED[:json_body] }, PASSWORD: PLANTED[:upcase_param]),
           "CONTENT_TYPE" => "application/json"

      files = Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) }
      expect(files).not_to be_empty
      stored = files.map { |f| File.read(f) }.join("\n")

      leaked = PLANTED.values_at(:root_param, :upcase_param, :regex_param, :json_body,
                                 :authorization, :cookie, :set_cookie, :response_json, :env)
                      .map { |v| v.split(/[ =;]/).max_by(&:length) }
                      .select { |v| stored.include?(v) }
      expect(leaked).to eq([])
    ensure
      ENV.delete("PROFILER_SPEC_UNLISTED_VAR")
    end
  end
end
