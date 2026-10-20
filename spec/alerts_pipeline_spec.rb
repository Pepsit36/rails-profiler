# frozen_string_literal: true

require "spec_helper"
require "rack/test"
require "logger"
require "stringio"

# Alerts on the profile the real pipeline records: the middleware, the real collectors and
# Profiler.save_profile, so the profile Alerts.check receives has the symbol keys the collectors
# write (a hand-built hash with string keys hid that the SQL alerts never fired).
RSpec.describe Profiler::Alerts, "on a profile recorded by the real pipeline" do
  include Rack::Test::Methods

  let(:received) { [] }

  let(:inner_app) do
    lambda do |_env|
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM users WHERE id = 1",
                                                                   name: "User Load", binds: [], connection: nil) do
        sleep 0.15
      end
      3.times do |i|
        ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM posts WHERE user_id = #{i}",
                                                                     name: "Post Load", binds: [], connection: nil)
      end
      [200, { "Content-Type" => "text/html" }, ["<html><body>hello</body></html>"]]
    end
  end

  def app
    Profiler::Middleware::ProfilerMiddleware.new(inner_app)
  end

  def default_host
    "localhost"
  end

  before do
    Profiler.configure do |c|
      c.enabled = true
      c.collectors = [Profiler::Collectors::RequestCollector, Profiler::Collectors::DatabaseCollector]
      c.skip_paths = []
      c.track_memory = true
      c.track_http = false
      c.slow_query_threshold = 100
      c.max_queries_warning = 3
      c.allocated_objects_warning_threshold = 1
      c.alerts_enabled = true
      c.on_detection { |alert| received << alert }
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    allow_any_instance_of(Profiler::Collectors::RequestCollector)
      .to receive(:collect_route_info).and_return(controller_action: "OrdersController#index")
  end

  it "fires the four types of alert" do
    checked = []
    allow(described_class).to receive(:check).and_wrap_original do |original, profile|
      checked << profile
      original.call(profile)
    end
    get "/orders"
    described_class.drain

    profile = checked.last
    expect(profile.token).to eq(last_response.headers["X-Profiler-Token"])
    # What the alerts read has symbol keys, as DatabaseCollector#collect wrote it.
    expect(profile.collector_data("database")).to have_key(:queries)
    expect(profile.collector_data("database")[:queries].first).to have_key(:sql)

    expect(received.map { |a| a[:type] })
      .to contain_exactly("slow_query", "too_many_queries", "excessive_allocations", "n_plus_one")
    expect(received).to all(include(profile_token: profile.token, path: "/orders",
                                    controller_action: "OrdersController#index"))
    slow = received.find { |a| a[:type] == "slow_query" }
    expect(slow[:query][:sql]).to eq("SELECT * FROM users WHERE id = ?")
    expect(slow[:value]).to be > 100
    expect(received.find { |a| a[:type] == "too_many_queries" }).to include(value: 4)
    expect(received.find { |a| a[:type] == "n_plus_one" }[:patterns].first)
      .to include(sql: "SELECT * FROM posts WHERE user_id = ?", count: 3)
  end

  it "does not deliver the alerts of a profile again when it is saved again" do
    get "/orders"
    described_class.drain
    expect(received.size).to eq(4)

    profile = Profiler.storage.load(last_response.headers["X-Profiler-Token"])
    2.times do
      Profiler.save_profile(profile, from: "HttpCollector")
      described_class.drain
    end
    expect(received.size).to eq(4)
  end

  describe "the path of a console profile" do
    it "is left out of the payload, the expression typed may hold a secret" do
      profile = Profiler::Models::Profile.new
      profile.profile_type = "console"
      profile.path = "User.find_by(api_key: 'sk_live_SECRET')"
      profile.allocated_objects = 5000
      Profiler.save_profile(profile, from: "ConsoleProfiler")
      described_class.drain

      expect(received.size).to eq(1)
      expect(received.first[:path]).to be_nil
      expect(JSON.generate(received)).not_to include("sk_live_SECRET")
    end
  end
end
