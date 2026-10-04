# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::RequestCollector do
  let(:profile) do
    build_profile(
      path: "/users",
      method: "POST",
      status: 201,
      duration: 85.5,
      params: { "name" => "alice" },
      headers: { "Accept" => "application/json" }
    )
  end

  subject(:collector) { described_class.new(profile) }

  before { profile.finish(201, { "Content-Type" => "application/json" }) }

  describe "#collect" do
    before { collector.collect }

    it "stores path in panel_content" do
      expect(collector.panel_content[:path]).to eq("/users")
    end

    it "stores method in panel_content" do
      expect(collector.panel_content[:method]).to eq("POST")
    end

    it "stores status in panel_content" do
      expect(collector.panel_content[:status]).to eq(201)
    end

    it "stores params in panel_content" do
      expect(collector.panel_content[:params]).to include("name" => "alice")
    end
  end

  describe "#collect route info" do
    context "when Rails routes recognize the path" do
      let(:profile) do
        build_profile(path: "/users/42", method: "GET", status: 200)
      end

      before do
        route_double = double("route")
        path_double = double("path")
        spec_double = double("spec", to_s: "/users/:id(.:format)")

        allow(route_double).to receive(:defaults).and_return({ controller: "users", action: "show" })
        allow(route_double).to receive(:path).and_return(path_double)
        allow(path_double).to receive(:match).with("/users/42").and_return(true)
        allow(path_double).to receive(:spec).and_return(spec_double)

        named_routes = { "user" => route_double }
        routes_double = double("routes")
        allow(routes_double).to receive(:recognize_path)
          .with("/users/42", method: "GET")
          .and_return({ controller: "users", action: "show", id: "42" })
        allow(routes_double).to receive(:named_routes).and_return(named_routes)

        rails_app = double("rails_app")
        allow(rails_app).to receive(:routes).and_return(routes_double)
        # Read by the redaction filter, which also masks route params.
        allow(rails_app).to receive(:config).and_return(double("config", filter_parameters: []))
        stub_const("Rails", double("Rails", application: rails_app, respond_to?: true))

        collector.collect
      end

      it "stores controller_action" do
        expect(collector.panel_content[:controller_action]).to eq("UsersController#show")
      end

      it "stores route_params without controller/action" do
        expect(collector.panel_content[:route_params]).to eq({ id: "42" })
      end

      it "stores route_name with _path suffix" do
        expect(collector.panel_content[:route_name]).to eq("user_path")
      end

      it "stores route_pattern without format suffix" do
        expect(collector.panel_content[:route_pattern]).to eq("/users/:id")
      end
    end

    context "when route recognition fails" do
      before do
        routes_double = double("routes")
        allow(routes_double).to receive(:recognize_path).and_raise(StandardError.new("no route"))

        rails_app = double("rails_app")
        allow(rails_app).to receive(:routes).and_return(routes_double)
        stub_const("Rails", double("Rails", application: rails_app, respond_to?: true))

        collector.collect
      end

      it "does not store route_name" do
        expect(collector.panel_content[:route_name]).to be_nil
      end

      it "does not store controller_action" do
        expect(collector.panel_content[:controller_action]).to be_nil
      end
    end
  end

  describe "#toolbar_summary" do
    it "returns green color for 2xx status" do
      profile.instance_variable_set(:@status, 200)
      expect(collector.toolbar_summary[:color]).to eq("green")
    end

    it "returns blue color for 3xx status" do
      profile.instance_variable_set(:@status, 301)
      expect(collector.toolbar_summary[:color]).to eq("blue")
    end

    it "returns orange color for 4xx status" do
      profile.instance_variable_set(:@status, 404)
      expect(collector.toolbar_summary[:color]).to eq("orange")
    end

    it "returns red color for 5xx status" do
      profile.instance_variable_set(:@status, 500)
      expect(collector.toolbar_summary[:color]).to eq("red")
    end

    it "includes method and status in text" do
      profile.instance_variable_set(:@method, "GET")
      profile.instance_variable_set(:@status, 200)
      expect(collector.toolbar_summary[:text]).to eq("GET 200")
    end
  end
end
