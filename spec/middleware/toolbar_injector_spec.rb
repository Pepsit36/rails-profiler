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

    context "with the page as a String" do
      let(:injector) { described_class.new("<html><body>hi</body></html>", token) }

      it "injects the toolbar" do
        expect(injector.inject.join).to include("profiler-toolbar")
      end
    end

    # The middleware reads the page; the injector never iterates or closes a response body.
    context "with an Array of parts" do
      it "joins them" do
        result = described_class.new(["<html><body>", "hi</body></html>"], token).inject
        expect(result.join).to include("hi")
        expect(result.join).to include("profiler-toolbar")
      end
    end

    # A page can carry "</body>" elsewhere than in its closing tag: in a script string, a
    # style sheet or a comment, before or after the real one. Injected there, the toolbar's
    # own </script> would close the page's script and turn the rest of its string into live
    # markup, or the toolbar would sit in a comment.
    describe "choosing the </body>" do
      let(:alert) { %(</body><img src=x onerror=alert(1)>) }

      def inject(html)
        described_class.new([html], token).inject.join
      end

      def toolbar_before(content, marker)
        position = content.index('<div id="profiler-toolbar"')
        expect(position).not_to be_nil
        expect(position).to be < content.index(marker)
        position
      end

      it "skips one in a script string before the real one" do
        html = %(<html><body><script>var tpl = "#{alert}";</script><p>end</p></body></html>)
        content = inject(html)

        expect(content).to start_with(%(<html><body><script>var tpl = "#{alert}";</script><p>end</p>))
        expect(toolbar_before(content, "</body></html>")).to be > content.index("<p>end</p>")
      end

      it "skips one in a script placed after the real one" do
        html = %(<html><body><p>end</p></body><script>var tpl = "#{alert}";</script></html>)
        content = inject(html)

        toolbar_before(content, %(</body><script>var tpl))
        expect(content).to end_with(%(</body><script>var tpl = "#{alert}";</script></html>))
        expect(content.scan("onerror").size).to eq(1)
      end

      it "skips one in a comment closing the page" do
        html = %(<html><body><p>end</p></body></html>\n<!-- cached </body> -->)
        content = inject(html)

        toolbar_before(content, "</body></html>")
        expect(content).to end_with(%(</body></html>\n<!-- cached </body> -->))
      end

      it "skips one in a style sheet" do
        html = %(<html><head><style>/* </body> */ p { color: red }</style></head><body><p>end</p></body></html>)
        content = inject(html)

        expect(content).to start_with(%(<html><head><style>/* </body> */ p { color: red }</style></head><body><p>end</p>))
        toolbar_before(content, "</body></html>")
      end

      it "leaves the page alone when the only </body> is in a script or a comment" do
        html = %(<html><body><p>end</p><script>var tpl = "#{alert}";</script><!-- </body> -->)

        expect(inject(html)).to eq(html)
      end

      it "leaves the page alone when a script or a comment is never closed" do
        html = %(<html><body><p>end</p><script>var tpl = "</body>";)

        expect(inject(html)).to eq(html)
      end

      it "accepts a closing tag in upper case or with spaces" do
        content = inject(%(<html><body><p>end</p></BODY ></html>))

        toolbar_before(content, "</BODY ></html>")
      end

      it "does not take a <scripts> element or a </bodyx> tag for what they are not" do
        content = inject(%(<html><body><scripts></bodyx><p>end</p></body></html>))

        expect(toolbar_before(content, "</body></html>")).to be > content.index("<p>end</p>")
      end

      it "handles a page that is not valid UTF-8" do
        html = "<html><body><p>caf\xE9</p></body></html>".dup.force_encoding("UTF-8")
        content = inject(html)

        expect(content.b).to start_with("<html><body><p>caf\xE9</p>".b)
        toolbar_before(content.b, "</body></html>".b)
      end

      # A quoted attribute value is not markup: injected there, the toolbar's own quotes would
      # close the attribute and turn the rest of the value into live markup.
      it "skips one in a single-quoted attribute value after the real one" do
        html = %(<html><body><p>end</p></body><div title='#{alert}'></div></html>)
        content = inject(html)

        toolbar_before(content, %(</body><div title='))
        expect(content).to end_with(%(</body><div title='#{alert}'></div></html>))
      end

      it "skips one in a double-quoted attribute value after the real one" do
        html = %(<html><body><p>end</p></body><div title="#{alert}"></div></html>)
        content = inject(html)

        toolbar_before(content, %(</body><div title="))
        expect(content).to end_with(%(</body><div title="#{alert}"></div></html>))
      end

      it "leaves alone a page whose only </body> is in an attribute value" do
        html = %(<html><body><div data-props='{"html":"#{alert}"}'></div></html>)

        expect(inject(html)).to eq(html)
      end

      it "skips quotes that do not follow an equals sign, as the browser does" do
        content = inject(%(<html><body><div a"b c='x'>"</div><p>end</p></body></html>))

        expect(toolbar_before(content, "</body></html>")).to be > content.index("<p>end</p>")
      end

      it "leaves the page alone when a tag or a quoted value is never closed" do
        [
          %(<html><body><p>end</p></body><div title="#{alert}),
          %(<html><body><p>end</p><div title="x></body></html>),
          %(<html><body><p>end</p></body><div title=x)
        ].each { |html| expect(inject(html)).to eq(html) }
      end

      %w[xmp iframe noembed noframes noscript].each do |name|
        it "skips one in a <#{name}> element" do
          html = %(<html><body><p>end</p></body><#{name}>#{alert}</#{name}></html>)
          content = inject(html)

          toolbar_before(content, "</body><#{name}>")
          expect(content).to end_with(%(</body><#{name}>#{alert}</#{name}></html>))
        end
      end

      it "leaves the page alone after a <plaintext>, which never closes" do
        html = %(<html><body><plaintext></body></html>)

        expect(inject(html)).to eq(html)
      end

      # In a script, <!-- followed by <script enters a state where </script> does not close
      # it: rather than follow it, the page is left without a toolbar.
      it "leaves the page alone after a double-escaped script" do
        html = %(<html><body><script><!--<script></script>"#{alert}"--></script><p>end</p></body></html>)

        expect(inject(html)).to eq(html)
      end

      it "still injects after a script holding a plain <!-- comment" do
        content = inject(%(<html><body><script><!-- var a = 1; //--></script><p>end</p></body></html>))

        expect(toolbar_before(content, "</body></html>")).to be > content.index("<p>end</p>")
      end

      # The browser reads attributes as its tokenizer does: an = where an attribute name
      # starts is part of the name, and only tab, line feed, form feed, carriage return and
      # space separate them (not a vertical tab).
      [
        %(<p ="><script>">),
        %(<p a="1"="><script>">),
        %(<p/="><script>">),
        %(<p a=\v"><script>">)
      ].each do |tag|
        it "sees the script opened by #{tag.inspect} after the real </body>" do
          tail = %(</body>#{tag}var a = "#{alert}";</script></html>)
          content = inject(%(<html><body><p>end</p>#{tail}))

          toolbar_before(content, tail)
          expect(content).to end_with(tail)
        end
      end

      it "leaves the page alone when its only </body> is in a script opened by <p =\">" do
        html = %(<html><body><p>end</p><p ="><script>">var a = "#{alert}";</script></html>)

        expect(inject(html)).to eq(html)
      end

      it "does not take </body followed by a vertical tab for the closing tag" do
        html = %(<html><body><p>end</p></body\v></html>)

        expect(inject(html)).to eq(html)
      end

      it "scans many scripts in linear time" do
        html = "<html><body>#{"<script>a()</script>" * 40_000}<p>end</p></body></html>"
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        content = inject(html)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        toolbar_before(content, "</body></html>")
        expect(elapsed).to be < 1.0
      end

      # Outside <svg> and <math>, <![CDATA[ is a bogus comment that ends at the first >; inside,
      # a CDATA section that ends at ]]>. The scanner does not follow foreign content, so it
      # only goes on when both readings agree.
      it "skips a CDATA section without > before its end" do
        content = inject(%(<html><body><svg><![CDATA[ a < b ]]></svg><p>end</p></body></html>))

        expect(toolbar_before(content, "</body></html>")).to be > content.index("<p>end</p>")
      end

      it "leaves the page alone rather than inject into a CDATA section holding a >" do
        html = %(<html><body><p>end</p></body><svg><![CDATA[ a > b </body> ]]></svg></html>)

        expect(inject(html)).to eq(html)
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
