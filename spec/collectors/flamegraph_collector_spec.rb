# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/flamegraph_collector"

RSpec.describe Profiler::Collectors::FlameGraphCollector do
  let(:profile) { build_profile }
  subject(:collector) { described_class.new(profile) }

  def make_event(name:, started_at:, finished_at:, category:, payload: {})
    Profiler::Models::TimelineEvent.new(
      name: name,
      started_at: started_at,
      finished_at: finished_at,
      category: category,
      payload: payload
    )
  end

  describe "#tab_config" do
    it "returns correct configuration" do
      config = collector.tab_config
      expect(config[:key]).to eq("flamegraph")
      expect(config[:label]).to eq("Flame Graph")
      expect(config[:priority]).to eq(30)
    end
  end

  describe "#subscribe" do
    it "registers thread-local collector reference" do
      collector.subscribe
      expect(Thread.current[:profiler_flamegraph_collector]).to eq(collector)
      collector.collect # cleanup
    end

    it "subscribes to ActiveSupport::Notifications" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "UsersController", action: "show",
        format: :html, method: "GET", path: "/users/1", status: 200) {}

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("controller")
      expect(events.first.name).to eq("UsersController#show")

      collector.collect
    end

    it "captures SQL queries" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("sql.active_record",
        sql: "SELECT * FROM users WHERE id = 1", name: "User Load") {}

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("sql")

      collector.collect
    end

    it "captures cache operations" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("cache_read.active_support",
        key: "posts:count", hit: true) {}

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("cache")

      collector.collect
    end

    it "captures template rendering" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("render_template.action_view",
        identifier: "/app/views/users/show.html.erb", layout: "application") {}

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("view")
      expect(events.first.name).to include("users/show.html.erb")

      collector.collect
    end

    it "captures partial rendering" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("render_partial.action_view",
        identifier: "/app/views/users/_card.html.erb") {}

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("partial")
      expect(events.first.name).to include("users/_card.html.erb")

      collector.collect
    end

    it "captures controller, view and partial events together" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "PostsController", action: "index",
        format: :html, method: "GET", path: "/posts", status: 200) {}
      ActiveSupport::Notifications.instrument("render_template.action_view",
        identifier: "/app/views/posts/index.html.erb", layout: "application") {}
      ActiveSupport::Notifications.instrument("render_partial.action_view",
        identifier: "/app/views/posts/_post.html.erb") {}

      events = collector.instance_variable_get(:@events)
      categories = events.map(&:category)
      expect(categories).to contain_exactly("controller", "view", "partial")

      collector.collect
    end

    it "skips schema and transaction SQL" do
      collector.subscribe

      ActiveSupport::Notifications.instrument("sql.active_record",
        sql: "BEGIN", name: "TRANSACTION") {}
      ActiveSupport::Notifications.instrument("sql.active_record",
        sql: "COMMIT", name: "TRANSACTION") {}
      ActiveSupport::Notifications.instrument("sql.active_record",
        sql: "SELECT 1", name: "SCHEMA") {}

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(0)

      collector.collect
    end
  end

  describe "#record_http_event" do
    it "adds an HTTP event" do
      collector.record_http_event(
        started_at: 100.0,
        finished_at: 100.5,
        url: "https://api.example.com/data",
        method: "GET",
        status: 200
      )

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("http")
      expect(events.first.name).to include("api.example.com")
    end
  end

  describe "#record_custom_event" do
    it "adds a custom event with the given label" do
      collector.record_custom_event(
        label: "payment.stripe_charge",
        started_at: 100.0,
        finished_at: 100.05,
        metadata: { amount: 1000 }
      )

      events = collector.instance_variable_get(:@events)
      expect(events.size).to eq(1)
      expect(events.first.category).to eq("custom")
      expect(events.first.name).to eq("payment.stripe_charge")
      expect(events.first.payload).to eq({ amount: 1000 })
    end

    it "adds a custom event with empty metadata by default" do
      collector.record_custom_event(
        label: "pdf.render",
        started_at: 100.0,
        finished_at: 100.02
      )

      events = collector.instance_variable_get(:@events)
      expect(events.first.payload).to eq({})
    end

    it "nests correctly inside parent events in the hierarchy" do
      events = collector.instance_variable_get(:@events)
      events << make_event(name: "Controller#show", started_at: 100.0, finished_at: 100.1, category: "controller")
      collector.record_custom_event(
        label: "report.generate",
        started_at: 100.02,
        finished_at: 100.08,
        metadata: { rows: 500 }
      )

      collector.collect
      data = collector.panel_content

      root = data[:root_events].first
      expect(root[:children].size).to eq(1)
      custom = root[:children].first
      expect(custom[:category]).to eq("custom")
      expect(custom[:name]).to eq("report.generate")
    end
  end

  describe "#collect" do
    it "clears thread-local collector reference" do
      collector.subscribe
      collector.collect
      expect(Thread.current[:profiler_flamegraph_collector]).to be_nil
    end

    it "stores empty data for no events" do
      collector.collect
      data = collector.panel_content
      expect(data[:total_events]).to eq(0)
      expect(data[:total_duration]).to eq(0)
      expect(data[:root_events]).to eq([])
    end

    it "builds correct hierarchy for nested events" do
      events = collector.instance_variable_get(:@events)
      # Controller wraps everything: 0 -> 150ms
      events << make_event(name: "Controller#show", started_at: 100.0, finished_at: 100.15, category: "controller")
      # View inside controller: 5ms -> 140ms
      events << make_event(name: "Render: show", started_at: 100.005, finished_at: 100.14, category: "view")
      # SQL inside view: 30ms -> 35ms
      events << make_event(name: "SELECT * FROM users", started_at: 100.030, finished_at: 100.035, category: "sql")

      collector.collect
      data = collector.panel_content

      expect(data[:total_events]).to eq(3)
      expect(data[:root_events].size).to eq(1)

      root = data[:root_events].first
      expect(root[:name]).to eq("Controller#show")
      expect(root[:children].size).to eq(1)

      view = root[:children].first
      expect(view[:name]).to eq("Render: show")
      expect(view[:children].size).to eq(1)

      sql = view[:children].first
      expect(sql[:name]).to eq("SELECT * FROM users")
      expect(sql[:children]).to eq([])
    end

    it "handles sibling events at the same level" do
      events = collector.instance_variable_get(:@events)
      # Parent
      events << make_event(name: "Controller#index", started_at: 100.0, finished_at: 100.1, category: "controller")
      # Two siblings
      events << make_event(name: "Partial: _header", started_at: 100.01, finished_at: 100.03, category: "partial")
      events << make_event(name: "Partial: _footer", started_at: 100.05, finished_at: 100.08, category: "partial")

      collector.collect
      data = collector.panel_content

      root = data[:root_events].first
      expect(root[:children].size).to eq(2)
      expect(root[:children][0][:name]).to eq("Partial: _header")
      expect(root[:children][1][:name]).to eq("Partial: _footer")
    end

    it "handles deep nesting (controller > view > partial > SQL)" do
      events = collector.instance_variable_get(:@events)
      events << make_event(name: "Controller#show", started_at: 100.0, finished_at: 100.2, category: "controller")
      events << make_event(name: "Render: show", started_at: 100.01, finished_at: 100.19, category: "view")
      events << make_event(name: "Partial: _profile", started_at: 100.02, finished_at: 100.18, category: "partial")
      events << make_event(name: "SELECT * FROM posts", started_at: 100.05, finished_at: 100.06, category: "sql")

      collector.collect
      data = collector.panel_content

      root = data[:root_events].first
      expect(root[:children].size).to eq(1) # view
      view = root[:children].first
      expect(view[:children].size).to eq(1) # partial
      partial = view[:children].first
      expect(partial[:children].size).to eq(1) # sql
      expect(partial[:children].first[:category]).to eq("sql")
    end

    it "includes category in serialized events" do
      events = collector.instance_variable_get(:@events)
      events << make_event(name: "SELECT 1", started_at: 100.0, finished_at: 100.001, category: "sql")

      collector.collect
      data = collector.panel_content

      expect(data[:root_events].first[:category]).to eq("sql")
    end
  end

  describe "#toolbar_summary" do
    it "returns event count" do
      collector.instance_variable_set(:@events, [
        make_event(name: "A", started_at: 0, finished_at: 0.1, category: "controller")
      ])
      expect(collector.toolbar_summary[:text]).to eq("1 events")
      expect(collector.toolbar_summary[:color]).to eq("blue")
    end
  end
end
