# frozen_string_literal: true

require "spec_helper"
require "socket"
require "stringio"
require "logger"
require "open3"
require "rbconfig"

RSpec.describe Profiler::Alerts do
  let(:received) { [] }
  let(:enabled) { true }

  before do
    Profiler.configure do |c|
      c.alerts_enabled = enabled
      c.slow_query_threshold = 100
      c.max_queries_warning = 3
      c.allocated_objects_warning_threshold = 1000
      c.on_detection { |alert| received << alert }
    end
  end

  def query(sql, duration = 1.0)
    { "sql" => sql, "duration" => duration }
  end

  def profile_with(queries: [], allocated_objects: 10, params: {})
    data = { "database" => { "queries" => queries },
             "request" => { "controller_action" => "OrdersController#index" } }
    profile = build_profile(path: "/orders", method: "GET", params: params, collectors_data: data)
    profile.allocated_objects = allocated_objects
    profile
  end

  # Alerts.check works on a thread of its own: wait for it.
  def run_check(profile)
    described_class.check(profile)&.join
  end

  def types
    received.map { |a| a[:type] }
  end

  describe "slow query" do
    it "calls on_detection with the threshold, the slowest duration and the route" do
      profile = profile_with(queries: [query("SELECT * FROM a WHERE id = 5", 250.5), query("SELECT 1 FROM b", 1)])
      run_check(profile)

      alert = received.find { |a| a[:type] == "slow_query" }
      expect(alert).to include(threshold: 100, value: 250.5, unit: "ms", count: 1, profile_token: profile.token,
                               path: "/orders", method: "GET", controller_action: "OrdersController#index")
      expect(alert[:query][:sql]).to eq("SELECT * FROM a WHERE id = ?")
    end

    it "is not called when no query is over the threshold" do
      run_check(profile_with(queries: [query("SELECT 1 FROM a", 100.0)]))
      expect(types).not_to include("slow_query")
    end
  end

  describe "too many queries" do
    it "is called above max_queries_warning" do
      qs = Array.new(4) { |i| query("SELECT #{i}_x FROM t#{i}") }
      run_check(profile_with(queries: qs))
      expect(received.find { |a| a[:type] == "too_many_queries" }).to include(threshold: 3, value: 4)
    end

    it "is not called at the threshold" do
      qs = Array.new(3) { |i| query("SELECT x FROM t#{i}") }
      run_check(profile_with(queries: qs))
      expect(types).not_to include("too_many_queries")
    end
  end

  describe "excessive allocations" do
    it "is called above allocated_objects_warning_threshold" do
      run_check(profile_with(allocated_objects: 1001))
      expect(received.find { |a| a[:type] == "excessive_allocations" })
        .to include(threshold: 1000, value: 1001, unit: "objects")
    end

    it "is not called at or below it" do
      run_check(profile_with(allocated_objects: 1000))
      expect(received).to be_empty
    end

    it "uses the non deprecated threshold name" do
      expect(Profiler.configuration).to respond_to(:allocated_objects_warning_threshold)
    end
  end

  describe "N+1" do
    it "is called when a normalized statement repeats in the request" do
      qs = [query("SELECT * FROM users WHERE id = 1"), query("SELECT * FROM users WHERE id = 2")]
      run_check(profile_with(queries: qs))
      alert = received.find { |a| a[:type] == "n_plus_one" }
      expect(alert[:patterns]).to contain_exactly(include(sql: "SELECT * FROM users WHERE id = ?", count: 2))
    end

    it "is not called when every statement differs" do
      qs = [query("SELECT * FROM users WHERE id = 1"), query("SELECT * FROM posts WHERE id = 1")]
      run_check(profile_with(queries: qs))
      expect(types).not_to include("n_plus_one")
    end
  end

  describe "when alerts are not enabled" do
    let(:enabled) { false }

    it "triggers nothing" do
      run_check(profile_with(queries: [query("SELECT 1", 900), query("SELECT 1", 900)],
                             allocated_objects: 10**9))
      expect(received).to be_empty
    end

    it "is off by default" do
      expect(Profiler::Configuration.new.alerts_enabled).to be(false)
    end
  end

  it "runs when a profile is saved" do
    Profiler.configuration.storage = :memory
    Profiler.save_profile(profile_with(allocated_objects: 5000), from: "spec")
    Timeout.timeout(5) { sleep 0.01 while received.empty? }
    expect(types).to eq(["excessive_allocations"])
  end

  it "swallows and logs an error of the hook" do
    io = StringIO.new
    Profiler.configuration.logger = Logger.new(io)
    Profiler.configuration.on_detection { |_| raise "boom" }
    expect { run_check(profile_with(allocated_objects: 5000)) }.not_to raise_error
    expect(io.string).to include("on_detection raised").and include("boom")
  end

  describe "the webhook" do
    let(:server) { TCPServer.new("127.0.0.1", 0) }
    let(:url) { "http://127.0.0.1:#{server.addr[1]}/hook" }
    let(:bodies) { Queue.new }

    # Accepts every connection until the server is closed, and queues each body.
    def serve(answer: true)
      Thread.new do
        loop { handle(server.accept, answer) }
      rescue IOError, Errno::EBADF
        nil
      end
    end

    def handle(conn, answer)
      Thread.new do
        headers = +""
        while (line = conn.gets) && line != "\r\n"
          headers << line
        end
        bodies << conn.read(headers[/content-length: (\d+)/i, 1].to_i)
        conn.write("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") if answer
        sleep 2 unless answer
        conn.close
      end
    end

    before { Profiler.configuration.alert_webhook_url = url }
    after { server.close }

    it "posts the alert as JSON" do
      serve
      run_check(profile_with(allocated_objects: 5000))
      payload = JSON.parse(Timeout.timeout(5) { bodies.pop })
      expect(payload).to include("type" => "excessive_allocations", "value" => 5000, "threshold" => 1000,
                                 "controller_action" => "OrdersController#index")
      expect(payload["profile_token"]).to match(/\A\h{32}\z/)
    end

    it "does not post without a URL" do
      Profiler.configuration.alert_webhook_url = nil
      expect(Net::HTTP).not_to receive(:new)
      run_check(profile_with(allocated_objects: 5000))
    end

    it "runs on a thread that holds nothing of the request" do
      collector = Object.new
      seen = Queue.new
      allow(Profiler::Alerts::Webhook).to receive(:send_request) do
        seen << [Thread.current[:profiler_http_collector], Thread.current.equal?(Thread.main)]
      end
      Thread.current[:profiler_http_collector] = collector
      begin
        run_check(profile_with(allocated_objects: 5000))
        expect(Timeout.timeout(5) { seen.pop }).to eq([nil, false])
        # Outside of detached, the same Thread.new would have carried the collector.
        expect(Thread.new { Thread.current[:profiler_http_collector] }.value).to equal(collector)
      ensure
        Thread.current[:profiler_http_collector] = nil
      end
    end

    it "does not wait for the webhook" do
      gate = Queue.new
      allow(Profiler::Alerts::Webhook).to receive(:send_request) { gate.pop }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      thread = described_class.check(profile_with(allocated_objects: 5000))
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
      gate << :go
      thread.join
    end

    it "logs a timeout without raising it nor slowing the request" do
      io = StringIO.new
      Profiler.configuration.logger = Logger.new(io)
      Profiler.configuration.alert_webhook_timeout = 0.3
      serve(answer: false)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      thread = nil
      expect { thread = described_class.check(profile_with(allocated_objects: 5000)) }.not_to raise_error
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.2
      thread.join
      Timeout.timeout(5) { sleep 0.05 until io.string.include?("webhook failed") }
      expect(io.string).to include("webhook failed for excessive_allocations")
    end

    it "logs an unreachable host" do
      io = StringIO.new
      Profiler.configuration.logger = Logger.new(io)
      Profiler.configuration.alert_webhook_url = "http://127.0.0.1:1/hook"
      expect { run_check(profile_with(allocated_objects: 5000)) }.not_to raise_error
      Timeout.timeout(5) { sleep 0.05 until io.string.include?("webhook failed") }
    end

    it "carries no raw sensitive data" do
      serve
      sql = "SELECT * FROM users WHERE email = 'victim@example.com' AND api_key = 'sk_live_SECRET' AND id = 4242"
      profile = profile_with(queries: [query(sql, 500), query(sql.sub("4242", "4243"), 1)],
                             allocated_objects: 5000, params: { "password" => "hunter2-PASSWORD" })
      profile.request_body = '{"password":"hunter2-PASSWORD"}'
      profile.response_body = "response-BODY-secret"
      run_check(profile)
      json = Timeout.timeout(5) { Array.new(3) { bodies.pop } }.join
      expect(json.scan('"type"').size).to eq(3)
      %w[victim@example.com sk_live_SECRET 4242 4243 hunter2 PASSWORD response-BODY].each do |leak|
        expect(json).not_to include(leak)
      end
      expect(json).to include("users WHERE email = ?")
      received.each { |alert| expect(JSON.generate(alert)).not_to include("sk_live_SECRET") }
    end
  end

  describe "isolation of the alert families" do
    it "still sends the other alerts when one family raises" do
      io = StringIO.new
      Profiler.configuration.logger = Logger.new(io)
      allow(described_class).to receive(:normalize_sql).and_raise(NameError, "uninitialized constant MCP")
      qs = [query("SELECT 1 FROM a", 500), query("SELECT 2 FROM a", 1), query("SELECT 3 FROM a", 1),
            query("SELECT 4 FROM a", 1)]
      run_check(profile_with(queries: qs, allocated_objects: 5000))
      expect(types).to include("excessive_allocations", "too_many_queries")
      expect(types).not_to include("slow_query", "n_plus_one")
      expect(io.string).to include("could not detect slow_query").and include("could not detect n_plus_one")
    end
  end

  describe "a fresh process" do
    it "sends the alerts without the MCP server having been loaded that never loaded the MCP server" do
      script = <<~RUBY
        require "profiler"
        require "profiler/models/profile"
        abort "MCP server loaded" if defined?(Profiler::MCP::Server)
        Profiler.configure do |c|
          c.alerts_enabled = true
          c.slow_query_threshold = 100
          c.allocated_objects_warning_threshold = 1000
          c.on_detection { |a| puts a[:type] }
        end
        profile = Profiler::Models::Profile.new
        profile.allocated_objects = 5000
        profile.collectors_data["database"] = { "queries" => [{ "sql" => "SELECT 1", "duration" => 500.0 }] }
        Profiler::Alerts.check(profile).join
      RUBY
      out, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
      expect(status).to be_success, out
      expect(out.split).to contain_exactly("slow_query", "excessive_allocations")
    end
  end

  describe "SQL literals" do
    let(:statements) do
      {
        "mysql backslash" => "SELECT * FROM u WHERE a = 'a\\'SECRETVALUE b' AND id = 5",
        "mysql backslash then quote" => "SELECT 'C:\\' AND x = 'SECRETVALUE'",
        "doubled quote" => "SELECT * FROM u WHERE a = 'it''s SECRETVALUE' AND b = 1",
        "double quotes" => 'SELECT * FROM u WHERE a = "SECRETVALUE x" AND b = 1',
        "block comment" => "SELECT /* SECRETVALUE */ 1 FROM u",
        "line comment" => "SELECT 1 FROM u -- SECRETVALUE\n WHERE x = 1",
        "dollar quoting" => "SELECT $$SECRETVALUE body$$, $tag$SE'CRETVALUE$tag$ FROM u",
        "unterminated" => "SELECT * FROM u WHERE a = 'SECRETVALUE"
      }
    end

    it "leaves no fragment of the value in the payload sent" do
      statements.each do |name, sql|
        received.clear
        run_check(profile_with(queries: [query(sql, 500), query(sql, 1)]))
        json = JSON.generate(received)
        expect(received.map { |a| a[:type] }).to include("slow_query", "n_plus_one")
        expect(json).not_to include("SECRET"), "#{name}: #{json}"
        expect(json).not_to include("CRETVALUE"), "#{name}: #{json}"
      end
    end

  end

  it "keeps the statement readable around plain literals" do
    sql = "SELECT * FROM u WHERE a = 'x' AND id = 5"
    expect(described_class.normalize_sql(sql)).to eq("SELECT * FROM u WHERE a = ? AND id = ?")
  end

  describe "the hook and the request" do
    it "does not make save_profile wait for a slow on_detection" do
      Profiler.configuration.storage = :memory
      Profiler.configuration.on_detection { |alert| (sleep 0.5) && (received << alert) }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Profiler.save_profile(profile_with(allocated_objects: 5000), from: "spec")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
      Timeout.timeout(5) { sleep 0.01 while received.empty? }
      expect(types).to eq(["excessive_allocations"])
    end
  end
end
