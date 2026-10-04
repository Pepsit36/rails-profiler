# frozen_string_literal: true

require "spec_helper"
require_relative "../support/rails_app"
require "profiler/collectors/database_collector"
require "profiler/collectors/flamegraph_collector"
require "profiler/collectors/log_collector"

# The middlewares Rails places between the profiler and ShowExceptions raise straight through
# the profiler. ActionDispatch::RemoteIp is one of them: a Client-IP header that contradicts
# X-Forwarded-For makes it raise IpSpoofAttackError before any controller runs.
RSpec.describe "Profiler middleware on a request the Rails stack refuses", type: :request do
  include Rack::Test::Methods

  def app
    Rails.application
  end

  def default_host
    "localhost"
  end

  # From this machine, as :allow_local requires. X-Forwarded-For names a loopback address,
  # so the profiler captures the request; Client-IP contradicts it, so RemoteIp raises.
  let(:spoofed) do
    {
      "REMOTE_ADDR" => "127.0.0.1",
      "HTTP_HOST" => "localhost",
      "HTTP_X_FORWARDED_FOR" => "127.0.0.2",
      "HTTP_CLIENT_IP" => "203.0.113.7"
    }
  end

  def sql_subscribers
    ActiveSupport::Notifications.notifier.listeners_for("sql.active_record").size
  end

  def log_sinks
    Rails.logger.broadcasts.size
  end

  def get_spoofed
    get "/hello", {}, spoofed
  rescue ActionDispatch::RemoteIp::IpSpoofAttackError
    nil
  end

  before do
    Profiler.configure do |config|
      config.enabled = true
      config.collectors = [
        Profiler::Collectors::DatabaseCollector,
        Profiler::Collectors::FlameGraphCollector,
        Profiler::Collectors::LogCollector
      ]
      config.track_http = false
    end
    Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
    Profiler::LocalRequest.reset_warning!
  end

  it "raises IpSpoofAttackError from RemoteIp, below the profiler" do
    expect { get "/hello", {}, spoofed }.to raise_error(ActionDispatch::RemoteIp::IpSpoofAttackError)
  end

  it "leaves no subscriber and no log sink behind after repeated forged requests" do
    subscribers = sql_subscribers
    sinks = log_sinks

    10.times { get_spoofed }

    expect(sql_subscribers).to eq(subscribers)
    expect(log_sinks).to eq(sinks)
  end

  it "keeps a profile of the refused request, with status 500" do
    get_spoofed
    profiles = Profiler.storage.list
    expect(profiles.map(&:status)).to eq([500])
  end

  it "profiles a normal request as before" do
    subscribers = sql_subscribers
    get "/hello", {}, { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" }

    expect(last_response.status).to eq(200)
    expect(last_response.headers["X-Profiler-Token"]).not_to be_nil
    expect(sql_subscribers).to eq(subscribers)
  end
end
