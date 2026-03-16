# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Middleware::ToolbarInjector do
  before do
    Profiler.configure do |c|
      c.track_ajax = false
    end
  end

  let(:token) { "abc123token" }

  describe "#inject" do
    context "when body contains </body>" do
      let(:html) { "<html><body><h1>Hello</h1></body></html>" }
      let(:injector) { described_class.new([html], token) }

      it "injects the toolbar div before </body>" do
        result = injector.inject
        content = result.join
        expect(content).to include('<div id="profiler-toolbar" data-token="abc123token">')
        expect(content).to include("</body>")
        expect(content.index("profiler-toolbar")).to be < content.index("</body>")
      end

      it "embeds the token in data-token attribute" do
        result = injector.inject
        expect(result.join).to include('data-token="abc123token"')
      end

      it "returns an array" do
        expect(injector.inject).to be_an(Array)
      end
    end

    context "when body has no </body>" do
      let(:html) { "<div>fragment</div>" }
      let(:injector) { described_class.new([html], token) }

      it "returns body unchanged" do
        result = injector.inject
        expect(result).to eq([html])
      end
    end

    context "with array body" do
      let(:injector) { described_class.new(["<html><body>", "</body></html>"], token) }

      it "joins parts and injects toolbar" do
        result = injector.inject
        expect(result.join).to include("profiler-toolbar")
      end
    end

    context "with object that has a .body method" do
      let(:body_obj) do
        obj = double("body")
        allow(obj).to receive(:body).and_return("<html><body>hi</body></html>")
        obj
      end

      let(:injector) { described_class.new(body_obj, token) }

      it "extracts content via .body method" do
        result = injector.inject
        expect(result.join).to include("profiler-toolbar")
      end
    end
  end
end
