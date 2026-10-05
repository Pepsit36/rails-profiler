# frozen_string_literal: true

# Whether each profile holds its own request's work and only that, on a real Puma with 8 threads.
#
#   bundle exec ruby script/bench/puma_attribution.rb
#
# 40 concurrent requests. Each request runs one SQL query of its own,
# one in a Concurrent::Promises future, and one outgoing HTTP call in a future. Afterwards, each
# profile is checked for queries of other requests (foreign) and its own future's query (lost).
ENV["RAILS_ENV"] = "development"
require "bundler/setup"
require "logger"; require "tmpdir"; require "net/http"; require "socket"
require "rails"; require "action_controller/railtie"
require "profiler"; require "profiler/railtie"; require "profiler/engine"
require "puma"; require "puma/server"; require "concurrent"

backend = TCPServer.new("0.0.0.0", 0)
BACKEND_PORT = backend.addr[1]
Thread.new do
  loop do
    c = backend.accept
    Thread.new(c) do |s|
      while (l = s.gets) && l != "\r\n"; end
      sleep 0.01
      s.write "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"; s.close
    end
  end
end

PAGE = lambda do |env|
  id = Rack::Utils.parse_query(env["QUERY_STRING"])["id"]
  sql = ->(t) { ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT '#{id}' /* #{t} */", name: "Load", binds: []) {} }
  sql.call("own")
  Concurrent::Promises.future { sleep(rand * 0.01); sql.call("future") }.value!
  Concurrent::Promises.future { Net::HTTP.get(URI("http://127.0.0.2:#{BACKEND_PORT}/?id=#{id}")) }.value!
  sleep(rand * 0.02)
  [200, { "content-type" => "text/plain", "x-id" => id }, ["ok"]]
end

class App < Rails::Application
  config.root = Dir.mktmpdir; config.eager_load = false; config.logger = Logger.new(nil)
  config.secret_key_base = "d" * 64; config.hosts.clear
  config.profiler.enabled = true; config.profiler.storage = :memory; config.profiler.max_profiles = 1000
  routes.append { get "/page", to: PAGE }
end
App.initialize!
Profiler.configuration.collectors = [Profiler::Collectors::DatabaseCollector, Profiler::Collectors::HttpCollector]

Profiler.storage # created before the burst: Profiler.storage is not memoized under a lock (reported separately)
server = Puma::Server.new(App, nil, { min_threads: 8, max_threads: 8, log_writer: Puma::LogWriter.null })
port = server.add_tcp_listener("127.0.0.1", 0).addr[1]
server.run

tokens = {}
mutex = Mutex.new
Array.new(40) { |i| i }.each_slice(8).each do |slice|
  slice.map do |i|
    Thread.new do
      res = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/page?id=r#{i}"))
      mutex.synchronize { tokens["r#{i}"] = res["x-profiler-token"] }
    end
  end.each(&:join)
end
sleep 0.5
foreign = lost = http_foreign = http_lost = 0
tokens.each do |id, token|
  p = Profiler.storage.load(token)
  next puts("no profile for #{id}") unless p
  sqls = (p.collector_data("database")["queries"] || []).map { |q| q["sql"] }
  foreign += sqls.count { |s| !s.include?("'#{id}'") }
  lost += 1 unless sqls.any? { |s| s.include?("'#{id}' /* future */") }
  urls = ((p.collector_data("http") || {})["requests"] || []).map { |r| r["url"] }
  http_foreign += urls.count { |u| !u.include?("id=#{id}") }
  http_lost += 1 unless urls.any? { |u| u.include?("id=#{id}") }
end
puts "ruby #{RUBY_VERSION}, #{tokens.size} requests, Puma 8 threads: SQL foreign #{foreign}, future SQL lost #{lost}; HTTP foreign #{http_foreign}, HTTP lost #{http_lost}"
server.stop(true)
