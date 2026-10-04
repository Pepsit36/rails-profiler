# frozen_string_literal: true

require "spec_helper"

# The dashboard displays values captured from the profiled application (bodies, headers,
# SQL, emails) in the profiler's origin, which is the application's own. The front end has
# no test runner, so these examples read its sources and fail on the constructs that turn
# such a value into live markup or script.
RSpec.describe "Front-end HTML sinks" do
  root = File.expand_path("../app/assets", __dir__)

  # Comments are left out, so that one may name what the code avoids. A // after a colon
  # (a URL in a string) is not a comment.
  strip_comments = lambda do |code|
    code.gsub(%r{/\*.*?\*/}m) { |comment| "\n" * comment.count("\n") }
        .gsub(%r{(^|[^:\\])//.*$}, '\1')
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

  it "only assigns string literals to innerHTML or outerHTML" do
    assignments = offending_lines(/\.(innerHTML|outerHTML)\s*\+?=(?!=)/)
    literal = /\.(innerHTML|outerHTML)\s*=\s*('[^'`$\\]*'|"[^"`$\\]*")\s*([;})]|$)/

    expect(assignments.reject { |line| line.split(": ", 2).last.match?(literal) }).to be_empty
  end

  it "never parses markup from a string" do
    parsers = /insertAdjacentHTML|dangerouslySetInnerHTML|document\.write|createContextualFragment|
               setHTMLUnsafe|parseHTMLUnsafe|DOMParser/x

    expect(offending_lines(parsers)).to be_empty
  end

  it "never lets a sandboxed iframe run scripts or keep the profiler's origin" do
    expect(offending_lines(/allow-same-origin|allow-scripts/)).to be_empty
  end

  # srcdoc renders the captured email in the profiler's origin unless the iframe is fully
  # sandboxed.
  it "only uses srcdoc in the email preview, in an iframe with an empty sandbox" do
    expect(offending_lines(/srcdoc/i, only: sources.except(mailer_tab))).to be_empty

    iframes = sources.fetch(mailer_tab).scan(/<iframe\b.*?(?<!=)>/m)
    with_srcdoc = iframes.grep(/srcdoc/i)
    expect(with_srcdoc).not_to be_empty
    expect(with_srcdoc).to all(match(/\ssandbox=""(\s|\/?>)/))
    expect(with_srcdoc.join).not_to match(/sandbox=(?!""(\s|\/?>))/)
  end

  # A blob: URL inherits the profiler's origin: opened in a tab, a text/html or
  # image/svg+xml blob runs the scripts of the captured body.
  it "never creates a blob or a file of a captured, possibly active, type" do
    blobs = offending_lines(/new (Blob|File)\b/)
    inert = /type:\s*('text\/plain'|'application\/octet-stream'|inertPreviewType\(mime\))\s*\}\)/

    expect(blobs).not_to be_empty
    expect(blobs.reject { |line| line.match?(inert) }).to be_empty
  end

  it "only types a preview blob from a closed list of raster images and PDF" do
    code = sources.fetch(http_components)
    list = code[/^const INERT_PREVIEW_TYPES = \[([^\]]*)\]$/, 1]
    expect(list).not_to be_nil
    expect(list.scan(/'([^']*)'/).flatten).to all(match(%r{\A(image/(png|jpeg|gif|webp|avif)|application/pdf)\z}))
    expect(list.gsub(/'[^']*'|[\s,]/, "")).to be_empty

    body = code[/^function inertPreviewType\(mime: string\): string \{\n(.*?)^\}$/m, 1]
    expect(body).to eq(<<~TS.gsub(/^/, "  "))
      const m = mime.toLowerCase()
      return INERT_PREVIEW_TYPES.includes(m) ? m : 'application/octet-stream'
    TS
  end
end
