# frozen_string_literal: true

require "spec_helper"

# The dashboard displays values captured from the profiled application (bodies, headers,
# SQL, emails) in the profiler's origin, which is the application's own. The front end has
# no test runner, so these examples read its sources and fail on the constructs that turn
# such a value into live markup or script.
RSpec.describe "Front-end HTML sinks" do
  root = File.expand_path("../app/assets", __dir__)

  # Comments are blanked out (newlines kept), so that one may name what the code avoids.
  # Strings, template literals (and the code of their ${ } substitutions, nested ones
  # included) and regular expression literals are read as such, so that a // or a /* inside
  # one does not hide the code that follows. A // after a colon (a URL in JSX text) is not a
  # comment.
  strip_comments = lambda do |code|
    out = +""
    i = 0
    previous = nil # last significant character outside comments
    templates = [] # per open template literal: nil in its text, the brace depth in a ${ }
    while i < code.length
      char = code[i]
      pair = code[i, 2]
      if !templates.empty? && templates.last.nil?
        if char == "\\"
          out << pair
          i += 2
        elsif char == "`"
          templates.pop
          out << char
          i += 1
          previous = char
        elsif pair == "${"
          templates[-1] = 0
          out << pair
          i += 2
          previous = "{"
        else
          out << char
          i += 1
        end
      elsif pair == "//" && previous != ":"
        stop = code.index("\n", i) || code.length
        out << " " * (stop - i)
        i = stop
      elsif pair == "/*"
        stop = code.index("*/", i + 2)
        stop = stop ? stop + 2 : code.length
        out << code[i...stop].gsub(/[^\n]/, " ")
        i = stop
      elsif char == "`"
        templates.push(nil)
        out << char
        i += 1
      elsif char == "{" && !templates.empty?
        templates[-1] += 1
        out << char
        i += 1
        previous = char
      elsif char == "}" && !templates.empty?
        templates[-1] = templates.last.zero? ? nil : templates.last - 1
        out << char
        i += 1
        previous = char
      elsif ["'", '"'].include?(char) || (char == "/" && (previous.nil? || "(,=:[!&|?{};+-*%~^".include?(previous)))
        start = i
        i += 1
        in_class = false
        while i < code.length
          c = code[i]
          if c == "\\"
            i += 2
            next
          end
          break if c == "\n"
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

  it "reads the substitutions of template literals as code, nested ones included" do
    code = %(a = `x ${`//`} y`; el.innerHTML = z; b = `${ { c: `${d /* e */}` } }` // f)

    expect(strip_comments.call(code)).to eq(%(a = `x ${`//`} y`; el.innerHTML = z; b = `${ { c: `${d        }` } }`     ))
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

  it "never renders a script, style, object or embed element, nor builds one" do
    expect(offending_lines(/<(script|style|object|embed)\b/i)).to be_empty
    expect(offending_lines(/createElement(NS)?\([^)]*['"`](script|style|iframe|object|embed|frame)\b/i)).to be_empty
  end

  it "never runs a string as code through a timer or a javascript: URL" do
    expect(offending_lines(/set(Timeout|Interval)\(\s*['"`]|javascript:/i)).to be_empty
  end

  # A link or a resource built on a captured value could take a javascript: or a foreign
  # URL. JSX href/src take a string literal, a template literal starting with a fixed path
  # or with the base64 SVG data prefix, the BASE constant, or one of the object URLs this
  # code creates; nothing else assigns a URL.
  it "only builds links and resource URLs on fixed prefixes or object URLs" do
    attributes = offending_lines(/\b(href|src|action|formAction|poster|xlinkHref)=\{/)
    allowed = /\b(href|src|action|formAction|poster|xlinkHref)=\{(
                 `(\/|\$\{BASE\}\/|data:image\/svg\+xml;base64,)[^`]*`|
                 BASE|url|objectUrl|downloadUrl|href
               )\}/x
    expect(attributes).not_to be_empty
    expect(attributes.select { |line| line.split(": ", 2).last.gsub(allowed, "").match?(/\b(href|src|action|formAction|poster|xlinkHref)=\{/) }).to be_empty

    # The href prop is ToolbarItem's own, which the toolbar fills with fixed paths.
    expect(offending_lines(/href=\{href\}/).map { |line| line.split(":").first }.uniq).to eq(["typescript/profiler/components/toolbar/ToolbarItem.tsx"])
    expect(offending_lines(/<ToolbarItem\b[^>]*\bhref=(?!\{`\/_profiler\/)/)).to be_empty

    assignments = offending_lines(/\.(href|src|action)\s*=(?!=)|setAttribute\(\s*['"`](href|src|action|xlink:href)|\blocation(\.href)?\s*=(?!=)|location\.(assign|replace)\(|window\.open\(/)
    expect(assignments).to eq(["typescript/profiler/components/dashboard/tabs/EnvTab.tsx:#{sources.fetch("typescript/profiler/components/dashboard/tabs/EnvTab.tsx").lines.index { |l| l.include?("a.href = url") } + 1}: a.href = url"])
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
