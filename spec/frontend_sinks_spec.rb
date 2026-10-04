# frozen_string_literal: true

require "spec_helper"

# The dashboard displays values captured from the profiled application (bodies, headers,
# SQL, emails) in the profiler's origin, which is the application's own. The front end has
# no test runner, so these examples read its sources and fail on the constructs that turn
# such a value into live markup or script.
RSpec.describe "Front-end HTML sinks" do
  root = File.expand_path("../app/assets", __dir__)

  # Comments are blanked out (newlines kept), so that one may name what the code avoids.
  # Strings, template literals and regular expression literals are read as such, so that a
  # // or a /* inside one does not hide the code that follows. A // after a colon (a URL in
  # JSX text) is not a comment.
  strip_comments = lambda do |code|
    out = +""
    i = 0
    previous = nil # last significant character outside comments
    while i < code.length
      char = code[i]
      pair = code[i, 2]
      if pair == "//" && previous != ":"
        stop = code.index("\n", i) || code.length
        out << " " * (stop - i)
        i = stop
      elsif pair == "/*"
        stop = code.index("*/", i + 2)
        stop = stop ? stop + 2 : code.length
        out << code[i...stop].gsub(/[^\n]/, " ")
        i = stop
      elsif ["'", '"', "`"].include?(char) || (char == "/" && (previous.nil? || "(,=:[!&|?{};+-*%~^".include?(previous)))
        start = i
        i += 1
        in_class = false
        while i < code.length
          c = code[i]
          if c == "\\"
            i += 2
            next
          end
          break if char != "/" && c == "\n" && char != "`"
          in_class = true if char == "/" && c == "["
          in_class = false if char == "/" && c == "]"
          i += 1
          break if c == char && !in_class
        end
        out << code[start...i]
        previous = char
      else
        out << char
        previous = char unless char.match?(/\s/)
        i += 1
      end
    end
    out
  end

  sources = Dir.glob(File.join(root, "{typescript,javascript}", "**", "*.{ts,tsx,js}"))
               .reject { |path| path.include?("/generated/") }
               .to_h { |path| [path.delete_prefix("#{root}/"), strip_comments.call(File.read(path))] }

  mailer_tab = "typescript/profiler/components/dashboard/tabs/MailerTab.tsx"
  http_components = "typescript/profiler/components/dashboard/tabs/shared/HttpComponents.tsx"

  define_method(:sources) { sources }

  def offending_lines(pattern, only: sources)
    only.flat_map do |path, code|
      code.each_line.with_index(1).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end
  end

  it "reads the front-end sources" do
    expect(sources.keys).to include("typescript/profiler/main.tsx", mailer_tab, http_components)
  end

  it "keeps the line count while blanking comments, and reads strings as strings" do
    code = %(a = "/*"; el.innerHTML = x; b = "*/" // c\nd = /\\/\\*/; e = '//' + f /* g\nh */ i)

    expect(strip_comments.call(code)).to eq(%(a = "/*"; el.innerHTML = x; b = "*/"     \nd = /\\/\\*/; e = '//' + f     \n     i))
  end

  # Assignment, JSX prop (<span innerHTML={...} />, which Preact assigns), object key
  # (Object.assign(el, { innerHTML })) or bracket access: only the assignment of a string
  # literal is allowed.
  it "only assigns string literals to innerHTML or outerHTML" do
    mentions = offending_lines(/(inner|outer)HTML/)
    literal = /\.(innerHTML|outerHTML)\s*=\s*('[^'`$\\]*'|"[^"`$\\]*")\s*([;})]|$)/

    expect(mentions.reject { |line| line.split(": ", 2).last.match?(literal) && line.scan(/(inner|outer)HTML/).size == 1 }).to be_empty
  end

  it "never parses markup or code from a string" do
    parsers = /insertAdjacentHTML|dangerouslySetInnerHTML|document\.write|createContextualFragment|
               setHTMLUnsafe|parseHTMLUnsafe|DOMParser|\beval\b|\bFunction\s*\(|new\s+Function\b/x

    expect(offending_lines(parsers)).to be_empty
  end

  it "never lets a sandboxed iframe run scripts or keep the profiler's origin" do
    expect(offending_lines(/allow-same-origin|allow-scripts/)).to be_empty
  end

  # srcdoc renders the captured email in the profiler's origin unless the iframe is fully
  # sandboxed. The only srcdoc is the JSX attribute of the email preview, on an iframe whose
  # sandbox is exactly empty; no iframe is built by hand.
  it "only uses srcdoc in the email preview, in an iframe with an empty sandbox" do
    expect(offending_lines(/srcdoc/i, only: sources.except(mailer_tab))).to be_empty
    expect(offending_lines(/createElement(NS)?\(.*['"`]iframe/i)).to be_empty

    code = sources.fetch(mailer_tab)
    expect(code.scan(/srcdoc/i).size).to eq(1)

    iframes = code.scan(/<iframe\b.*?(?<!=)>/m)
    with_srcdoc = iframes.grep(/\ssrcdoc=\{/)
    expect(with_srcdoc.size).to eq(1)
    expect(with_srcdoc.first).to match(/\ssandbox=""(\s|\/?>)/)
    expect(with_srcdoc.first).not_to match(/sandbox=(?!""(\s|\/?>))/)
  end

  # A blob: URL inherits the profiler's origin: opened in a tab, a text/html or
  # image/svg+xml blob runs the scripts of the captured body. Every blob is built by
  # new Blob([data], { type }) with an inert type; no File, no Response#blob.
  it "never creates a blob or a file of a captured, possibly active, type" do
    blobs = offending_lines(/\bBlob\b|\bFile\s*\(|new\s+(\w+\.)*File\b|\.blob\s*\(|\bResponse\s*\(/)
    inert = /(?<![.\w])new Blob\(\[\w+\], \{ type: ('text\/plain'|'application\/octet-stream'|inertPreviewType\(mime\)) \}\)/

    expect(blobs).not_to be_empty
    expect(blobs.reject { |line| line.match?(inert) && line.scan(/Blob/).size == 1 }).to be_empty
  end

  it "only types a preview blob from a closed, frozen list of raster images and PDF" do
    code = sources.fetch(http_components)
    list = code[/^const INERT_PREVIEW_TYPES = \[([^\]]*)\]$/, 1]
    expect(list).not_to be_nil
    expect(list.scan(/'([^']*)'/).flatten).to all(match(%r{\A(image/(png|jpeg|gif|webp|avif)|application/pdf)\z}))
    expect(list.gsub(/'[^']*'|[\s,]/, "")).to be_empty
    # The declaration and the one read below: nothing else can add to the list.
    expect(sources.values.join.scan(/INERT_PREVIEW_TYPES/).size).to eq(2)

    body = code[/^function inertPreviewType\(mime: string\): string \{\n(.*?)^\}$/m, 1]
    expect(body).to eq(<<~TS.gsub(/^/, "  "))
      const m = mime.toLowerCase()
      return INERT_PREVIEW_TYPES.includes(m) ? m : 'application/octet-stream'
    TS
  end
end
