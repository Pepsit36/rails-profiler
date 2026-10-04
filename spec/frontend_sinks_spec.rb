# frozen_string_literal: true

require "spec_helper"

# The dashboard displays values captured from the profiled application (bodies, headers,
# SQL, emails) in the profiler's origin, which is the application's own. The front end has
# no test runner, so these examples read its sources and fail on the constructs that turn
# such a value into live markup or script.
RSpec.describe "Front-end HTML sinks" do
  root = File.expand_path("../app/assets", __dir__)
  sources = Dir.glob(File.join(root, "{typescript,javascript}", "**", "*.{ts,tsx,js}"))
               .reject { |path| path.include?("/generated/") }
               .to_h { |path| [path.delete_prefix("#{root}/"), File.read(path)] }

  def offending_lines(sources, pattern)
    sources.flat_map do |path, code|
      code.each_line.with_index(1).filter_map { |line, number| "#{path}:#{number}: #{line.strip}" if line.match?(pattern) }
    end
  end

  it "reads the front-end sources" do
    expect(sources.keys).to include("typescript/profiler/main.tsx")
  end

  it "only assigns string literals to innerHTML, outerHTML or insertAdjacentHTML" do
    sinks = offending_lines(sources, /\.(innerHTML|outerHTML)\s*=(?!=)|insertAdjacentHTML\(|dangerouslySetInnerHTML|document\.write\(/)
    literal = /\.(innerHTML|outerHTML)\s*=\s*'[^'$`]*';?\s*$/

    expect(sinks.reject { |line| line.split(": ", 2).last.match?(literal) }).to be_empty
  end

  it "never gives a sandboxed iframe the profiler's origin" do
    expect(offending_lines(sources, /allow-same-origin/)).to be_empty
  end

  # A blob: URL inherits the profiler's origin: opened in a tab, a text/html or
  # image/svg+xml blob runs the scripts of the captured body.
  it "never creates a blob of a captured, possibly active, type" do
    blobs = offending_lines(sources, /new Blob\(/)
    inert = /type:\s*('text\/plain'|'application\/octet-stream'|inertPreviewType\()/

    expect(blobs).not_to be_empty
    expect(blobs.reject { |line| line.match?(inert) }).to be_empty
  end
end
