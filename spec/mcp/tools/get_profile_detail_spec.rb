# frozen_string_literal: true

require "spec_helper"
require "support/mcp_tool_schema"
require "profiler/collectors/mailer_collector"
require "profiler/mcp/body_formatter"
require "profiler/mcp/tools/get_profile_detail"

# The section renderers of get_profile; the body formatting options are in
# get_profile_detail_bodies_spec.rb.
RSpec.describe Profiler::MCP::Tools::GetProfileDetail do
  let(:dash) { "-" }

  let(:store) { Profiler::Storage::MemoryStore.new }

  before { Profiler.instance_variable_set(:@storage, store) }
  after { Profiler.instance_variable_set(:@storage, nil) }

  def save(**attrs)
    extra = attrs.slice(:allocated_objects, :gem_version, :response_body)
    build_profile(**attrs.except(*extra.keys)).tap do |profile|
      extra.each { |name, value| profile.public_send(:"#{name}=", value) }
      store.save(profile.token, profile)
    end
  end

  def detail(profile, *sections, **params)
    args = { "token" => profile.token }
    args["sections"] = sections unless sections.empty?
    described_class.call(args.merge(params.transform_keys(&:to_s))).first[:text]
  end

  it "declares the token as required and types every option" do
    schema = mcp_tool_schema("get_profile")

    expect(schema[:properties].transform_values { |p| p[:type] }).to eq(
      token: "string", sections: "array", save_bodies: "boolean", max_body_size: "number",
      json_path: "string", xml_path: "string", log_min_level: "string", env_filter: "string",
      slave: "string"
    )
    expect(schema[:properties][:sections][:items]).to eq(type: "string")
    expect(schema[:required]).to eq(["token"])
  end

  describe "the profile looked up" do
    it "requires a token" do
      expect(described_class.call({}).first[:text]).to eq("Error: token parameter is required")
    end

    it "says when the profile does not exist" do
      expect(described_class.call("token" => "missing").first[:text]).to eq("Profile not found: missing")
    end

    it "reads the most recent profile for the latest token" do
      save(started_at: Time.now - 60, path: "/older")
      newest = save(started_at: Time.now, path: "/newer")

      text = described_class.call("token" => "latest", "sections" => ["overview"]).first[:text]
      expect(text).to include("# Profile Details: #{newest.token}")
    end

    it "keeps only the sections asked for" do
      profile = save(collectors_data: { "job" => { "job_class" => "MailJob" } }, profile_type: "job")

      text = detail(profile, "job")
      expect(text).to start_with("## Job\n- Class: MailJob")
      expect(text).not_to include("# Profile Details")
    end

    it "renders every section when none is asked for" do
      profile = save(method: "GET", path: "/all")

      text = detail(profile)
      expect(text).to include("# Profile Details: #{profile.token}", "## Curl Command")
    end

    it "reads a slave's profile from the slave, without this process's routes and ENV" do
      slave_store = Profiler::Storage::MemoryStore.new
      profile = build_profile(path: "/on-slave", collectors_data: { "env" => { "total" => 0, "variables" => {} } })
      slave_store.save(profile.token, profile)
      allow(Profiler::MCP::SlaveSupport).to receive(:resolve_storage)
        .with(hash_including("slave" => "payment")).and_return(slave_store)
      expect(Profiler::ProcessSnapshot).not_to receive(:hydrate)

      text = described_class.call("token" => profile.token, "slave" => "payment", "sections" => ["overview"])
      expect(text.first[:text]).to include("**Request:** GET /on-slave")
    end
  end

  describe "overview" do
    it "describes an HTTP request with its allocations, gem version and parent" do
      profile = save(method: "POST", path: "/orders", status: 201, duration: 12.345,
                     allocated_objects: 4200, gem_version: "0.0.1-old", parent_token: "parent123")

      expect(detail(profile, "overview")).to eq(<<~MD)
        # Profile Details: #{profile.token}

        **Type:** HTTP Request
        **Request:** POST /orders
        **Status:** 201
        **Duration:** 12.35 ms
        **Allocated objects:** 4200
        **Time:** #{profile.started_at}
        **Gem Version:** 0.0.1-old ⚠️ (current: #{Profiler.version})
        **Parent Token:** parent123
      MD
    end

    it "shows the gem version alone when it is the current one" do
      profile = save(gem_version: Profiler.version)
      expect(detail(profile, "overview")).to include("**Gem Version:** #{Profiler.version}\n")
    end

    it "names a job and a console profile" do
      expect(detail(save(profile_type: "job"), "overview")).to include("**Type:** Job")
      expect(detail(save(profile_type: "console"), "overview")).to include("**Type:** Console")
    end
  end

  it "shows the exception with the first frames of its backtrace, app frames starred" do
    backtrace = [{ "location" => "app/models/order.rb:3", "app_frame" => true },
                 { "location" => "gems/x.rb:1", "app_frame" => false }]
    profile = save(collectors_data: { "exception" => { "exception_class" => "RuntimeError",
                                                       "message" => "boom", "backtrace" => backtrace } })

    expect(detail(profile, "exception")).to eq(<<~MD)
      ## Exception
      **Class:** RuntimeError
      **Message:** boom

      ### Backtrace
      ★ app/models/order.rb:3
        gems/x.rb:1
    MD
  end

  it "shows the job with its error and arguments" do
    profile = save(profile_type: "job", collectors_data: { "job" => {
      "job_class" => "MailJob", "job_id" => "j1", "queue" => "mailers", "executions" => 2,
      "status" => "failed", "error" => "SMTP down", "arguments" => [1, "two"]
    } })

    expect(detail(profile, "job")).to eq(<<~MD)
      ## Job
      - Class: MailJob
      - Job ID: j1
      - Queue: mailers
      - Executions: 2
      - Status: failed
      - Error: SMTP down
      - Arguments: 1, two
    MD
  end

  it "shows the console expression and its return value" do
    profile = save(profile_type: "console",
                   collectors_data: { "console" => { "expression" => "User.count", "return_value" => 3 } })

    expect(detail(profile, "console")).to eq("## Console\n**Expression:**\n```ruby\nUser.count\n```\n" \
                                             "**Return Value:**\n```\n3\n```\n")
  end

  describe "request and response" do
    it "lists the params and headers, and says the request body was truncated" do
      profile = save(collectors_data: { "request" => {
        "params" => { "q" => "shoes" }, "headers" => { "Accept" => "text/html" },
        "request_body" => "a=1", "request_body_encoding" => "text",
        "request_body_truncated" => true, "request_body_size" => 5000, "request_body_size_is_minimum" => true
      } })

      expect(detail(profile, "request")).to eq(<<~MD)
        ## Request Params
        - **q**: shoes

        ## Request Headers
        - **Accept**: text/html

        ## Request Body
        _Truncated: the body was at least 5000 bytes, only its beginning was kept (max_captured_body_bytes)._
        ```
        a=1
        ```
      MD
    end

    it "shows nothing for a profile without request data" do
      expect(detail(save, "request")).to eq("")
    end

    it "lists the response headers, and says the response body was truncated" do
      profile = save(response_headers: { "Content-Type" => "text/plain" }, response_body: "ok",
                     collectors_data: { "request" => { "response_body_truncated" => true } })

      text = detail(profile, "response")
      expect(text).to start_with("## Response Headers\n- **Content-Type**: text/plain\n\n## Response Body\n")
      expect(text).to include("_Truncated: the body was ? bytes, only its beginning was kept")
      expect(text).to include("ok")
    end
  end

  describe "curl" do
    def curl(method:, headers: {}, params: {})
      profile = save(method: method, path: "/items",
                     collectors_data: { "request" => { "headers" => headers, "params" => params } })
      detail(profile, "curl")
    end

    it "puts the params of a GET in the query string and drops the User-Agent" do
      text = curl(method: "GET", headers: { "User-Agent" => "x", "Accept" => "*/*" }, params: { "q" => "a b" })

      expect(text).to eq("## Curl Command\n```bash\ncurl -X GET \\\n  -H Accept:\\ \\*/\\* \\\n  " \
                         "http://localhost:3000/items\\?q\\=a+b\n```\n")
    end

    it "sends the params of a JSON POST as a JSON body" do
      text = curl(method: "POST", headers: { "Content-Type" => "application/json" }, params: { "a" => 1 })
      expect(text).to include("-d #{Shellwords.shellescape('{"a":1}')}")
    end

    it "sends the params of a form POST url-encoded" do
      text = curl(method: "PUT", params: { "a" => "1" })
      expect(text).to include("--data-urlencode a\\=1")
    end
  end

  it "lists the database queries with their backtrace" do
    profile = save(collectors_data: { "database" => {
      "total_queries" => 1, "total_duration" => 1.234, "slow_queries" => 0, "cached_queries" => 0,
      "queries" => [{ "sql" => "SELECT 1", "duration" => 1.234, "backtrace" => %w[a.rb:1 b.rb:2 c.rb:3 d.rb:4] }]
    } })

    expect(detail(profile, "database")).to eq(<<~MD)
      ## Database
      - Total Queries: 1
      - Total Duration: 1.23 ms
      - Slow Queries: 0
      - Cached Queries: 0

      ### Query Details

      **Query 1** (1.23ms):
      ```sql
      SELECT 1
      ```
      _Backtrace:_
        a.rb:1
        b.rb:2
        c.rb:3
    MD
  end

  it "lists the performance events" do
    profile = save(collectors_data: { "performance" => {
      "total_events" => 1, "total_duration" => 5.0, "events" => [{ "name" => "render", "duration" => 5.0 }]
    } })

    expect(detail(profile, "performance"))
      .to eq("## Performance Timeline\n- Total Events: 1\n- Total Duration: 5.0 ms\n\n### Events\n- **render**: 5.0 ms\n")
  end

  it "lists the templates and partials rendered" do
    profile = save(collectors_data: { "view" => {
      "total_views" => 1, "total_partials" => 1, "total_duration" => 3.0,
      "views" => [{ "identifier" => "index.html.erb", "duration" => 2.0 }],
      "partials" => [{ "identifier" => "_row.html.erb", "duration" => 1.0 }]
    } })

    expect(detail(profile, "views")).to eq(<<~MD)
      ## View Rendering
      - Templates: 1
      - Partials: 1
      - Total Duration: 3.0 ms

      ### Templates
      - `index.html.erb` #{dash} 2.0 ms

      ### Partials
      - `_row.html.erb` #{dash} 1.0 ms
    MD
  end

  it "lists the cache reads, writes and deletes" do
    profile = save(collectors_data: { "cache" => {
      "total_reads" => 2, "total_writes" => 1, "total_deletes" => 1, "hit_rate" => 50,
      "reads" => [{ "key" => "a", "hit" => true, "duration" => 0.1 }, { "key" => "b", "hit" => false, "duration" => 0.2 }],
      "writes" => [{ "key" => "b", "duration" => 0.3 }],
      "deletes" => [{ "key" => "c", "duration" => 0.4 }]
    } })

    expect(detail(profile, "cache")).to eq(<<~MD)
      ## Cache
      - Reads: 2
      - Writes: 1
      - Deletes: 1
      - Hit Rate: 50%

      ### Cache Reads
      - [HIT] `a` #{dash} 0.1 ms
      - [MISS] `b` #{dash} 0.2 ms

      ### Cache Writes
      - `b` #{dash} 0.3 ms

      ### Cache Deletes
      - `c` #{dash} 0.4 ms
    MD
  end

  it "lists the AJAX requests" do
    profile = save(collectors_data: { "ajax" => {
      "total_requests" => 1, "total_duration" => 4.0,
      "requests" => [{ "method" => "POST", "path" => "/api", "status" => 201, "duration" => 4.0, "token" => "t1" }]
    } })

    expect(detail(profile, "ajax"))
      .to include("- **POST /api** #{dash} 201 #{dash} 4.0 ms (token: t1)")
  end

  it "lists the outbound HTTP calls, flags the slow and failed ones and shows their bodies" do
    Profiler.configure { |c| c.slow_http_threshold = 100 }
    profile = save(collectors_data: { "http" => {
      "total_requests" => 2, "total_duration" => 250.0, "slow_requests" => 1, "error_requests" => 1,
      "requests" => [
        { "method" => "POST", "url" => "https://api.test/a", "status" => 500, "duration" => 200.0,
          "request_body" => "in", "response_body" => "out", "backtrace" => ["app/x.rb:1"] },
        { "method" => "GET", "url" => "https://api.test/b", "status" => 0, "duration" => 50.0 }
      ]
    } })

    text = detail(profile, "http")
    expect(text).to start_with("## Outbound HTTP\n- Total: 2\n- Total Duration: 250.0 ms\n- Slow (>100ms): 1\n- Errors: 1\n")
    expect(text).to include("**1. POST https://api.test/a** #{dash} 500 #{dash} 200.0 ms [SLOW] [ERROR]")
    expect(text).to include("**Request Body:**\n```\nin\n```", "**Response Body:**\n```\nout\n```")
    expect(text).to include("_Backtrace:_\n  app/x.rb:1")
    expect(text).to include("**2. GET https://api.test/b** #{dash} error #{dash} 50.0 ms [ERROR]")
  end

  it "lists the mailers, their loop warnings and delivery errors" do
    profile = save(collectors_data: { "mailer" => {
      "total" => 2, "deliver_now" => 1, "deliver_later" => 1, "failed" => 1, "multi_part_count" => 0,
      "truncated" => true,
      "loop_warnings" => [{ "message" => "UserMailer#welcome sent 2 times" }],
      "emails" => [
        { "mailer_class" => "UserMailer", "action" => "welcome", "subject" => "Hi", "to" => %w[a@x b@x c@x],
          "delivery_mode" => "deliver_now", "duration_ms" => 3 },
        { "mailer_class" => "UserMailer", "action" => "bye", "subject" => "Bye", "to" => "d@x", "error" => "SMTP" }
      ],
      "errors" => [{ "mailer_class" => "UserMailer", "action" => "bye", "error" => "SMTP" }]
    } })

    text = detail(profile, "mailers")
    expect(text).to include("- Truncated: yes (showing first #{Profiler::Collectors::MailerCollector::MAX_EMAILS})")
    expect(text).to include("### ⚠️ Loop Warnings\n- UserMailer#welcome sent 2 times")
    expect(text).to include("| UserMailer | welcome | Hi | a@x, b@x, … | deliver_now | 3ms | ✅ |")
    expect(text).to include("| UserMailer | bye | Bye | d@x | - | - | ❌ SMTP |")
    expect(text).to include("### Delivery Errors\n- **UserMailer#bye**: SMTP")
  end

  describe "routes" do
    it "shows the matched route against the process's route table" do
      allow(Profiler::ProcessSnapshot).to receive(:route_table).and_return([
        { name: "orders", pattern: "/orders", verb: "GET", controller_action: "orders#index" },
        { name: nil, pattern: "/up", verb: "GET", controller_action: "health#show" }
      ])
      profile = save(collectors_data: { "routes" => { "matched" => {
        "verb" => "GET", "pattern" => "/orders", "name" => "orders", "controller_action" => "orders#index"
      } } })

      expect(detail(profile, "routes")).to eq(<<~MD)
        ## Routes
        - Total routes: 2
        - **Matched:** `GET /orders`
          - Route name: orders_path
          - Controller#Action: orders#index
      MD
    end

    it "says when no route matched" do
      profile = save(profile_type: "job", collectors_data: { "routes" => { "total" => 4, "matched" => nil } })
      expect(detail(profile, "routes")).to eq("## Routes\n- Total routes: 4\n- No route matched\n")
    end
  end

  it "lists the variable dumps" do
    profile = save(collectors_data: { "dump" => { "count" => 2, "dumps" => [
      { "label" => "user", "file" => "a.rb", "line" => 3, "formatted" => "#<User>" },
      { "value" => [1] }
    ] } })

    expect(detail(profile, "dumps")).to eq(<<~MD)
      ## Variable Dumps
      - Count: 2

      ### user
      _Source: a.rb:3_
      ```
      #<User>
      ```
      ### Dump 2
      ```
      [1]
      ```
    MD
  end

  describe "logs" do
    let(:profile) do
      save(collectors_data: { "logs" => { "count" => 4, "errors" => 1, "warnings" => 1, "logs" => [
        { "level" => "DEBUG", "message" => "d" }, { "level" => "INFO", "message" => "i" },
        { "level" => "WARN", "message" => "w" }, { "level" => "ERROR", "message" => "e" }
      ] } })
    end

    it "lists every entry with its level" do
      expect(detail(profile, "logs")).to eq(<<~MD)
        ## Logs (4 total, 1 errors, 1 warnings)

        - 🔍 **DEBUG** d
        - ℹ️ **INFO** i
        - ⚠️ **WARN** w
        - ❌ **ERROR** e
      MD
    end

    it "keeps the entries at or above log_min_level, whatever its case" do
      text = detail(profile, "logs", log_min_level: "warn")
      expect(text).to include("**WARN** w", "**ERROR** e")
      expect(text).not_to include("**INFO**")
    end

    it "shows nothing when no entry reaches log_min_level" do
      expect(detail(profile, "logs", log_min_level: "FATAL")).to eq("")
    end
  end

  describe "env" do
    let(:profile) do
      save(profile_type: "job", collectors_data: { "env" => { "total" => 2,
                                                              "variables" => { "RAILS_ENV" => "test", "HOME" => "/h" } } })
    end

    it "asks for a filter instead of listing every variable" do
      expect(detail(profile, "env")).to include("#{2} variables captured._")
    end

    it "lists the variables whose name matches the filter, case-insensitively" do
      expect(detail(profile, "env", env_filter: "rails")).to eq("## ENV Variables (filter: rails)\n\n- `RAILS_ENV` = `test`\n")
    end

    it "says when no variable matches" do
      expect(detail(profile, "env", env_filter: "NOPE")).to include("_No variables matching 'NOPE'._")
    end

    it "reads an HTTP profile's variables from this process" do
      ENV["PROFILER_SPEC_DETAIL_VAR"] = "here"
      http = save(collectors_data: { "env" => { "total" => 0 } })

      expect(detail(http, "env", env_filter: "PROFILER_SPEC_DETAIL")).to include("- `PROFILER_SPEC_DETAIL_VAR` = `")
    ensure
      ENV.delete("PROFILER_SPEC_DETAIL_VAR")
    end
  end

  it "lists the missing translations and the most called keys" do
    profile = save(collectors_data: { "i18n" => {
      "locale" => "fr", "total" => 3, "missing_count" => 1,
      "lookups" => [{ "key" => "a" }, { "key" => "a" }, { "key" => "b", "locale" => "fr", "missing" => true }]
    } })

    expect(detail(profile, "i18n")).to eq(<<~MD)
      ## I18n
      - **Locale:** fr
      - **Total lookups:** 3
      - **Missing translations:** 1

      ### Missing Translations
      - `b` (fr)

      ### Most Called Keys (top 2)
      - `a`: 2×
      - `b`: 1×
    MD
  end

  describe "related jobs" do
    it "names the job that triggered the profile and lists its child jobs" do
      parent = save(profile_type: "job", duration: 7.0, path: "ParentJob",
                    collectors_data: { "job" => { "job_class" => "ParentJob", "status" => "completed" } })
      profile = save(parent_token: parent.token)
      child = save(profile_type: "job", parent_token: profile.token, duration: 2.0,
                   collectors_data: { "job" => { "job_class" => "ChildJob", "status" => "completed" } })
      save(parent_token: profile.token, is_ajax: true)

      text = detail(profile, "related_jobs")
      expect(text).to start_with("## Triggered By\n- **Type:** Job\n- **Class:** ParentJob\n- **Status:** completed\n" \
                                 "- **Duration:** 7.0 ms\n- **Token:** #{parent.token}\n")
      expect(text).to include("## Child Jobs (1)")
      expect(text).to include("| ChildJob | completed | 2.0 ms | #{child.token} |")
    end

    it "names the HTTP request that triggered a job" do
      parent = save(method: "POST", path: "/checkout", status: 302, duration: 9.0)
      profile = save(profile_type: "job", parent_token: parent.token)

      expect(detail(profile, "related_jobs")).to eq(<<~MD)
        ## Triggered By
        - **Type:** HTTP Request
        - **Request:** POST /checkout
        - **Status:** 302
        - **Duration:** 9.0 ms
        - **Token:** #{parent.token}
      MD
    end
  end
end
