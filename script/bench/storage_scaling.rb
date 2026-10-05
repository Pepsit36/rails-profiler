# frozen_string_literal: true

# What the storage costs as profiles pile up, in milliseconds.
#
#   bundle exec ruby script/bench/storage_scaling.rb
#   bundle exec ruby script/bench/storage_scaling.rb save    # one section: save, children or list
#
# save:     the file store, a save into a directory already holding 500, 2,000 and 10,000 profiles
#           of about 2 KB (no count cap, so that the directory keeps its size).
# children: find_by_parent, file and memory stores, 1,500 profiles of about 17 KB, 3 children.
# list:     GET /_profiler/api/profiles?limit=50 through the engine, file store, 1,500 profiles of
#           about 17 KB.
#
# Prints the mean over the measured calls, after a warm-up. Runs against older versions of the
# gem too, to compare: the options they do not know are passed and ignored.

ENV["RAILS_ENV"] = "development"

require "bundler/setup"
require "fileutils"
require "json"
require "logger"
require "securerandom"
require "tmpdir"
require "rails"
require "action_controller/railtie"
require "profiler"
require "profiler/railtie"
require "profiler/engine"
require "profiler/storage/file_store"
require "profiler/storage/memory_store"

SECTIONS = ARGV.empty? ? %w[save children list] : ARGV

module StorageBench
  module_function

  def profile(index, size:, parent_token: nil, profile_type: "http")
    started = Time.at(1_700_000_000 + index)
    data = {
      token: SecureRandom.hex(16), profile_type: profile_type, path: "/items/#{index}", method: "GET",
      status: 200, duration: 12.5, memory: 1024, started_at: started.iso8601, finished_at: (started + 0.01).iso8601,
      params: { "id" => index.to_s }, headers: { "Accept" => "text/html" }, response_headers: {},
      parent_token: parent_token, is_ajax: !parent_token.nil?, tabs: [],
      collectors_data: { "database" => { "total_queries" => 3, "queries" => [] } }
    }
    padding = size - JSON.generate(data).bytesize
    data[:response_body] = "x" * padding if padding.positive?
    Profiler::Models::Profile.from_hash(data)
  end

  # Writes the files directly, as a long-lived directory would hold them.
  def fill(dir, count, size:)
    FileUtils.mkdir_p(dir)
    count.times do |i|
      p = profile(i, size: size)
      File.write(File.join(dir, "#{p.token}.json"), p.to_json)
    end
  end

  def file_store(dir, **options)
    Profiler::Storage::FileStore.new(path: dir, **options)
  end

  def mean_ms(iterations)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times { |i| yield i }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000 / iterations
  end

  def report(label, ms)
    puts format("  %-58s %9.3f ms", label, ms)
  end
end

Profiler.configure do |config|
  config.enabled = true
  config.collectors = []
  config.track_http = false
end

if SECTIONS.include?("save")
  puts "save, file store, profiles of about 2 KB, no count cap"
  [500, 2_000, 10_000].each do |count|
    Dir.mktmpdir do |dir|
      StorageBench.fill(dir, count, size: 2_048)
      store = StorageBench.file_store(dir, max_profiles: nil)
      3.times { |i| p = StorageBench.profile(count + i, size: 2_048); store.save(p.token, p) } # warm-up, index built
      ms = StorageBench.mean_ms(100) { |i| p = StorageBench.profile(count + 10 + i, size: 2_048); store.save(p.token, p) }
      StorageBench.report("#{count} profiles on disk, per save", ms)
    end
  end
end

if SECTIONS.include?("children")
  puts "find_by_parent, 1,500 profiles of about 17 KB, 3 children"
  Dir.mktmpdir do |dir|
    StorageBench.fill(dir, 1_497, size: 17 * 1024)
    stores = { "file" => StorageBench.file_store(dir, max_profiles: 5_000),
               "memory" => Profiler::Storage::MemoryStore.new(max_profiles: 5_000) }
    parent = StorageBench.profile(2_000, size: 17 * 1024)
    stores["file"].save(parent.token, parent)
    3.times do |i|
      child = StorageBench.profile(2_001 + i, size: 17 * 1024, parent_token: parent.token)
      stores["file"].save(child.token, child)
    end
    stores["file"].list(limit: 5_000).each { |p| stores["memory"].save(p.token, p) }
    stores.each do |name, store|
      store.find_by_parent(parent.token)
      ms = StorageBench.mean_ms(10) { store.find_by_parent(parent.token) }
      StorageBench.report("#{name} store, per call", ms)
    end
  end
end

if SECTIONS.include?("list")
  require "rack/test"

  module StorageBenchApp
    class Application < Rails::Application
      config.root = Dir.mktmpdir("profiler-bench-app").tap { |dir| at_exit { FileUtils.remove_entry(dir) } }
      config.eager_load = false
      config.logger = Logger.new(nil)
      config.secret_key_base = "b" * 64
      config.hosts.clear
      routes.append { mount Profiler::Engine, at: "/_profiler" }
    end
  end
  StorageBenchApp::Application.initialize!
  Profiler.configure { |config| config.collectors = [] }

  puts "GET /_profiler/api/profiles?limit=50, file store, 1,500 profiles of about 17 KB"
  Dir.mktmpdir do |dir|
    StorageBench.fill(dir, 1_500, size: 17 * 1024)
    Profiler.instance_variable_set(:@storage, StorageBench.file_store(dir, max_profiles: 5_000))
    session = Rack::Test::Session.new(Rails.application)
    env = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" }
    session.get("/_profiler/api/profiles", { limit: 50 }, env)
    raise "status #{session.last_response.status}" unless session.last_response.status == 200

    ms = StorageBench.mean_ms(10) { session.get("/_profiler/api/profiles", { limit: 50 }, env) }
    StorageBench.report("first page, per request", ms)
    ms = StorageBench.mean_ms(10) { session.get("/_profiler/api/profiles", { limit: 50, offset: 1_400 }, env) }
    StorageBench.report("page at offset 1400, per request", ms)
    body = JSON.parse(session.last_response.body)
    puts "  page at offset 1400: #{body["profiles"].size} profiles, has_more #{body["has_more"]}"
  end
end
