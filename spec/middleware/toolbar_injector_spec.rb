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
        expect(content).to include('<div id="profiler-toolbar" class="profiler-root" data-token="abc123token">')
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

    # A page can carry "</body>" before its real closing tag, in a script string for
    # instance; the toolbar's own </script> would then close that script and turn the rest
    # of the string into live markup.
    context "when </body> also appears earlier in the page" do
      let(:html) do
        %(<html><body><script>var tpl = "</body><img src=x onerror=alert(1)>";</script><p>end</p></body></html>)
      end

      it "injects before the last </body> and leaves the earlier one alone" do
        content = described_class.new([html], token).inject.join

        expect(content).to start_with(%(<html><body><script>var tpl = "</body><img src=x onerror=alert(1)>";</script><p>end</p>))
        expect(content.index("profiler-toolbar")).to be > content.index("<p>end</p>")
        expect(content).to end_with("</body></html>")
      end
    end

    # The token and the nonce come from the gem and from Rails today; the injector escapes
    # them anyway, as it writes into the application's own page.
    context "with a token or a nonce carrying markup" do
      let(:hostile) { %q{x'"></div></script><script>alert(1)</script>} }
      let(:html) { "<html><body>hi</body></html>" }

      before { Profiler.configure { |c| c.track_ajax = true } }

      it "keeps the token inside its JavaScript string and its attribute" do
        content = described_class.new([html], hostile).inject.join

        expect(content).not_to include("<script>alert(1)")
        expect(content).not_to include("></div></script>")
        assignment = content[/window\.__PROFILER_PARENT_TOKEN__ = (.*);$/, 1]
        expect(JSON.parse(assignment)).to eq(hostile)
        expect(content).to include(%q{data-token="x&#39;&quot;&gt;&lt;/div&gt;&lt;/script&gt;})
      end

      it "keeps the nonce inside its attribute" do
        content = described_class.new([html], token, hostile).inject.join

        expect(content).not_to include("<script>alert(1)")
        expect(content).to include(%q{nonce="x&#39;&quot;&gt;})
      end
    end
  end
end
