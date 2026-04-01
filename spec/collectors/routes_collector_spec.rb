# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::RoutesCollector do
  let(:profile) { build_profile(path: "/users/42", method: "GET", status: 200) }
  subject(:collector) { described_class.new(profile) }

  describe "#tab_config" do
    it "returns key 'routes'" do
      expect(collector.tab_config[:key]).to eq("routes")
    end

    it "returns label 'Routes'" do
      expect(collector.tab_config[:label]).to eq("Routes")
    end
  end

  describe "#collect" do
    context "when Rails is not defined" do
      before do
        hide_const("Rails") if defined?(Rails)
        collector.collect
      end

      it "stores empty routes list" do
        expect(collector.panel_content[:routes]).to eq([])
      end

      it "stores total of 0" do
        expect(collector.panel_content[:total]).to eq(0)
      end
    end

    context "when Rails routes are available" do
      let(:route_double) { double("route") }
      let(:path_double)  { double("path") }
      let(:spec_double)  { double("spec", to_s: "/users/:id(.:format)") }
      let(:routes_double) { double("routes") }

      before do
        allow(route_double).to receive(:respond_to?).with(:internal).and_return(false)
        allow(route_double).to receive(:defaults).and_return({ controller: "users", action: "show" })
        allow(route_double).to receive(:path).and_return(path_double)
        allow(route_double).to receive(:verb).and_return("GET")
        allow(route_double).to receive(:name).and_return("user")
        allow(path_double).to receive(:spec).and_return(spec_double)

        allow(routes_double).to receive(:recognize_path)
          .with("/users/42", method: "GET")
          .and_return({ controller: "users", action: "show", id: "42" })
        allow(routes_double).to receive(:routes).and_return([route_double])

        rails_app = double("rails_app", routes: routes_double)
        stub_const("Rails", double("Rails", application: rails_app, respond_to?: true))

        collector.collect
      end

      it "stores total route count" do
        expect(collector.panel_content[:total]).to eq(1)
      end

      it "marks the matched route" do
        expect(collector.panel_content[:matched]).not_to be_nil
        expect(collector.panel_content[:matched][:controller_action]).to eq("UsersController#show")
      end

      it "marks route as matched in routes list" do
        expect(collector.panel_content[:routes].first[:matched]).to be true
      end

      it "strips format suffix from route pattern" do
        expect(collector.panel_content[:routes].first[:pattern]).to eq("/users/:id")
      end

      it "does not include covered field" do
        expect(collector.panel_content[:routes].first).not_to have_key(:covered)
      end
    end

    context "when route recognition fails" do
      before do
        routes_double = double("routes")
        allow(routes_double).to receive(:recognize_path).and_raise(StandardError.new("no route"))
        allow(routes_double).to receive(:routes).and_return([])

        rails_app = double("rails_app", routes: routes_double)
        stub_const("Rails", double("Rails", application: rails_app, respond_to?: true))

        collector.collect
      end

      it "stores nil for matched" do
        expect(collector.panel_content[:matched]).to be_nil
      end

      it "stores empty routes list" do
        expect(collector.panel_content[:routes]).to eq([])
      end
    end
  end

  describe "#toolbar_summary" do
    it "returns the matched pattern" do
      allow(collector).to receive(:panel_content).and_return({
        total: 10,
        matched: { pattern: "/users/:id", verb: "GET", matched: true }
      })
      expect(collector.toolbar_summary[:text]).to eq("/users/:id")
    end

    it "returns — when no route matched" do
      allow(collector).to receive(:panel_content).and_return({ total: 10, matched: nil })
      expect(collector.toolbar_summary[:text]).to eq("—")
    end
  end
end
