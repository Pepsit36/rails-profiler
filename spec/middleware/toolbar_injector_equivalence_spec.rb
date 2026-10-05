# frozen_string_literal: true

require "spec_helper"

# The toolbar goes where it went before the plain-markup shortcut: on generated pages made of the
# cases the injector has to get right, the position found with the shortcut is the one found by
# reading every tag one by one.
RSpec.describe Profiler::Middleware::ToolbarInjector, "plain-markup shortcut" do
  SEED = 20_261_005
  PAGES = 5_000

  FRAGMENTS = [
    "text ", "\n", "a > b ", "<p>", "</p>", "<div class=\"row\">", "</div>", "<a href='/x?a=1&b=2'>", "</a>",
    "<b data-x=z>", "<br/>", "<img src=x alt=\"\">", "<input disabled>", "<P CLASS=Up>",
    "<body>", "<BODY class=\"b\">", "</body>", "</BODY >", "</body\t>", "</body/>", "</bodyx>", "</html>",
    # </body> or > in a quoted value, and unquoted values
    "<div title=\"</body>\">", "<div title='a>b'>", "<div title=a>b>", "<a b = \"x>y\">",
    # = where a name starts, and a quote in a name
    "<a =\"x>\">", "<a =x>", "<a \"x=\"y\">", "<a b=\"\"c=\"d\">",
    # a quote never closed, a tag without its >
    "<div class=\"oops>", "<div title='oops>", "<div",
    # comments
    "<!-- </body> -->", "<!---->", "<!-->", "<!--->", "<!--", "<!-- a -- b -->",
    # raw-text elements
    "<script>var a = \"</body>\";</script>", "<script type=\"t\">x</script >", "<SCRIPT>1</SCRIPT>",
    "<scripts>", "</script>", "<script><!--<script></script>--></script>", "<script><!-- x --></script>",
    "<style>p > a { }</style>", "<textarea></body></textarea>", "<title>a</body></title>",
    "<noscript></body></noscript>", "<iframe></body></iframe>", "<xmp></body></xmp>", "<script>",
    # never closed
    "<plaintext>", "<PLAINTEXT x=1>",
    # CDATA, declarations, processing instructions, bogus comments
    "<svg><![CDATA[</body>]]></svg>", "<![CDATA[x>y]]>", "<![CDATA[x]]>", "<!DOCTYPE html>", "<?xml version=\"1.0\"?>",
    "</ x>", "</3>", "< p>", "<", ">", "<3", "</", "<!", "<?"
  ].freeze

  BIG_ATTRIBUTE = "<div data-big=\"#{"x" * 100_000}</body>\">".freeze

  let(:reference) do
    # The scan as it was before the shortcut: every tag read one by one.
    Class.new(described_class) do
      def skip_plain_markup(_scanner); end
    end
  end

  def position(klass, page)
    klass.new([page], "token").send(:closing_body_position, page.b)
  end

  it "finds the same place as a tag-by-tag scan on #{PAGES} generated pages (seed #{SEED})" do
    random = Random.new(SEED)
    found = 0
    refused = 0

    PAGES.times do |i|
      parts = Array.new(random.rand(1..30)) { FRAGMENTS[random.rand(FRAGMENTS.size)] }
      parts.insert(random.rand(parts.size + 1), BIG_ATTRIBUTE) if (i % 250).zero?
      parts << "</body></html>" if random.rand < 0.6
      page = parts.join

      expected = position(reference, page)
      expect(position(described_class, page)).to eq(expected), "page #{i}: #{page[0, 500].inspect}"
      expected ? found += 1 : refused += 1
    end

    # Both outcomes are exercised, not only one.
    expect(found).to be > PAGES / 10
    expect(refused).to be > PAGES / 10
  end

  it "keeps the shortcut on a page of ordinary markup" do
    page = "<html><body>#{"<p class=\"x\">row</p>" * 2_000}</body></html>"
    scanner = StringScanner.new(page.b)
    described_class.new([page], "token").send(:skip_plain_markup, scanner)

    expect(page.b.byteslice(scanner.pos, 7)).to eq("</body>")
  end
end
