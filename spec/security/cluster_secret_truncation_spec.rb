# frozen_string_literal: true

require "spec_helper"
require "profiler/redaction"
require "profiler/collectors/flamegraph_collector"
require "profiler/collectors/i18n_collector"
require "profiler/collectors/console_collector"
require "profiler/collectors/mailer_collector"
require "profiler/console_profiler"
require "profiler/test_runner/run_store"

# The cluster secret has to be masked before text is cut or split: a cut through it leaves a
# prefix, and pieces masked one by one give it back whole once joined.
RSpec.describe "Cluster secret and cut text" do
  let(:secret) { "c1uster-shared-value-0123456789abcdef-0123456789abcdef-012345678" }

  before { Profiler.configure { |config| config.cluster_secret = secret } }

  # Whether any 12 consecutive characters of the secret are left in +text+.
  def leaks?(text)
    text = text.to_s
    (0..secret.size - 12).any? { |i| text.include?(secret[i, 12]) }
  end

  describe "capture points that shorten text" do
    it "the flame graph name of a SQL query, cut at 80" do
      collector = Profiler::Collectors::FlameGraphCollector.new(Profiler::Models::Profile.new)
      collector.subscribe
      ActiveSupport::Notifications.instrument("sql.active_record", sql: "SELECT * FROM t WHERE v = '#{secret}'", name: "T")
      collector.unsubscribe if collector.respond_to?(:unsubscribe)

      names = collector.instance_variable_get(:@events).map(&:name)
      expect(names).not_to be_empty
      expect(names.none? { |name| leaks?(name) }).to be(true)
    end

    it "the flame graph name of a cache key, cut at 60" do
      collector = Profiler::Collectors::FlameGraphCollector.new(Profiler::Models::Profile.new)
      collector.subscribe
      ActiveSupport::Notifications.instrument("cache_read.active_support", key: "views/#{secret}", hit: true)
      collector.unsubscribe if collector.respond_to?(:unsubscribe)

      names = collector.instance_variable_get(:@events).map(&:name)
      expect(names).not_to be_empty
      expect(names.none? { |name| leaks?(name) }).to be(true)
    end

    it "an I18n value, cut at 100" do
      collector = Profiler::Collectors::I18nCollector.new(Profiler::Models::Profile.new)
      collector.record_lookup("k", "en", "#{"a" * 50}#{secret}")

      expect(leaks?(collector.instance_variable_get(:@lookups).first[:value])).to be(false)
    end

    it "a console expression, cut at 200 for the path" do
      Profiler.configure do |config|
        config.enabled = true
        config.track_console = true
      end
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      expression = "#{"x" * 180}#{secret}"

      Profiler::ConsoleProfiler.profile(expression: expression) { 1 }
      profile = Profiler.storage.list(limit: 1).first

      expect(leaks?(profile.path)).to be(false)
    end

    it "a console return value, cut at 10 000" do
      collector = Profiler::Collectors::ConsoleCollector.new(Profiler::Models::Profile.new, expression: "e")
      value = Object.new
      text = "#{"a" * 9_970}#{secret}"
      value.define_singleton_method(:inspect) { text }
      collector.set_return_value(value)

      expect(leaks?(collector.instance_variable_get(:@return_value))).to be(false)
    end

    it "a mailer assign, cut at 300" do
      collector = Profiler::Collectors::MailerCollector.new(Profiler::Models::Profile.new)
      value = Object.new
      text = "#{"a" * 270}#{secret}"
      value.define_singleton_method(:inspect) { text }

      expect(leaks?(collector.send(:serialize_assign, value))).to be(false)
    end

    it "a mail body, cut at MAX_BODY_SIZE" do
      collector = Profiler::Collectors::MailerCollector.new(Profiler::Models::Profile.new)
      body = "#{"a" * (Profiler::Collectors::MailerCollector::MAX_BODY_SIZE - 20)}#{secret}"
      mail = double("mail", multipart?: false, content_type: "text/plain", body: double(decoded: body))

      expect(collector.send(:extract_body, mail).compact.none? { |part| leaks?(part) }).to be(true)
    end

    it "a job argument, cut at 200" do
      job = Profiler::JobProfiler.new(job_class: "J", job_id: "1", queue: "q", arguments: [], executions: 1)
      args = job.send(:sanitize_arguments, ["#{"a" * 180}#{secret}"])

      expect(args.none? { |arg| leaks?(arg) }).to be(true)
    end
  end

  # A cut written later without Redaction.truncate would bring the defect back: the capture
  # code must not cut text by itself. Cuts of lists (whole lines kept) and cuts of text already
  # masked are listed below, each with its reason; output-side code (MCP tools, resources,
  # body_formatter) reads data masked when it was captured and is not scanned.
  RAW_CUT = /
    \[0,\s*[\w:]+\] | \[0\.\.\.?[\w:-]+\] | \[\.\.\.?[\w:]+\] |
    \.first\(\s*[\w:]+\s*\) | \.take\( | \.truncate\( | %\.\d+s |
    \.slice\(\s*0\s*, | \.byteslice\(\s*0\s*,
  /x

  ALLOWED_CUTS = {
    # Backtrace frames: a list of lines, cut by count; each frame is kept whole and masked with
    # the rest of the collector data.
    "collectors/exception_collector.rb" => ["raw_backtrace.first(30)"],
    "instrumentation/net_http_instrumentation.rb" => ["frames.first(depth)"],
    # A list of emails, cut by count; each email is masked whole.
    "collectors/mailer_collector.rb" => ["@emails.first(MAX_EMAILS)"],
    # The text shown so far, cut after it was masked on the joined text (see append_output).
    "test_runner/run_store.rb" => ["text.byteslice(0, cut)"],
    # A streamed response body, kept up to one byte past max_captured_body_bytes; what is
    # stored is then cut by Redaction.cut_bytes.
    "middleware/capturing_body.rb" => ["chunk.byteslice(0, room)"],
    # Segments of a test file path, cut by count; not captured text.
    "test_runner/discovery.rb" => ["parts[0..-2]"]
  }.freeze

  it "leaves no raw cut of text in the capture code" do
    root = File.expand_path("../../lib/profiler", __dir__)
    files = %w[collectors instrumentation middleware models test_runner].flat_map { |dir| Dir[File.join(root, dir, "*.rb")] } +
            Dir[File.join(root, "*_profiler.rb")]
    offenders = files.flat_map do |file|
      relative = file.delete_prefix("#{root}/")
      allowed = ALLOWED_CUTS.fetch(relative, [])
      File.readlines(file).each_with_index.filter_map do |line, i|
        next unless line.match?(RAW_CUT)
        next if line.include?("Redaction.truncate") || allowed.any? { |cut| line.include?(cut) }

        "#{relative}:#{i + 1}: #{line.strip}"
      end
    end

    expect(offenders).to eq([])
  end

  it "catches each form of cut it is meant to" do
    ['s[0, 80]', 's[0...n]', 's[0..n]', 's[..n]', 'l.first(3)', 'l.take(2)', 's.truncate(10)',
     'format("%.40s", s)', 's.slice(0, 5)', 's.byteslice(0, 5)'].each do |code|
      expect(code).to match(RAW_CUT)
    end
  end

  describe "test runner output, read in 256-byte chunks" do
    let(:store) { Profiler::TestRunner::RunStore.new }
    let(:output) { "#{"x" * 300}pp ENV: #{secret}\n#{"y" * 300}" }

    # Every offset of the secret against the 256-byte chunk boundaries.
    def each_offset
      (0...256).each do |offset|
        run = store.create(files: [], framework: "rspec")
        text = "#{"o" * offset}#{output}"
        text.b.scan(/.{1,256}/m).each { |chunk| store.append_output(run.id, chunk) }
        yield run, text
      end
    end

    it "never gives the secret back, whole or in part, while the run is going on" do
      each_offset do |run, _text|
        chunks = store.wait_for_output(run.id, position: 0, timeout: 0)[:chunks]

        expect(leaks?(chunks.join)).to be(false)
        expect(leaks?(store.find(run.id).to_h[:output])).to be(false)
        expect(leaks?(store.find(run.id).output_lines.join)).to be(false)
      end
    end

    it "gives the whole output, masked, once the output is finished" do
      each_offset do |run, text|
        store.finish_output(run.id)
        store.update(run.id, status: "passed", finished_at: Time.now)
        full = store.find(run.id).to_h[:output]

        expect(leaks?(full)).to be(false)
        expect(full).to eq(text.sub(secret, Profiler::Redaction::MASK))
      end
    end

    # A kill sets the status first; the process then prints its summary and flushes its buffers.
    # The end of the output is told by finish_output, never by the status.
    it "keeps holding back after a kill, until the output is finished" do
      runs = (0...256).map do |offset|
        run = store.create(files: [], framework: "rspec")
        text = "#{"o" * offset}#{output}"
        chunks = text.b.scan(/.{1,256}/m)
        half = chunks.size / 2
        chunks.first(half).each { |chunk| store.append_output(run.id, chunk) }
        store.update(run.id, status: "killed", finished_at: Time.now)
        chunks.drop(half).each { |chunk| store.append_output(run.id, chunk) }
        store.update(run.id, exit_code: 143)
        [offset, run, text]
      end

      leaked = runs.select { |_, run, _| leaks?(store.find(run.id).to_h[:output]) }.map(&:first)
      expect(leaked).to eq([])

      runs.each do |_, run, text|
        store.finish_output(run.id)
        expect(store.find(run.id).to_h[:output]).to eq(text.sub(secret, Profiler::Redaction::MASK))
      end
    end

    # Only the bytes that could start the secret wait: progress dots are shown as they come.
    it "holds back only an end of the text that could start the secret" do
      run = store.create(files: [], framework: "rspec")
      store.append_output(run.id, "....")
      store.append_output(run.id, "..F#{secret[0, 5]}")

      expect(store.find(run.id).to_h[:output]).to eq("......F")
      store.append_output(run.id, "x")
      expect(store.find(run.id).to_h[:output]).to eq("......F#{secret[0, 5]}x")
    end
  end

  describe "binary bodies, stored in base64" do
    require "profiler/instrumentation/net_http_instrumentation"

    def decoded(processed)
      Base64.strict_decode64(processed[:body])
    end

    it "masks the raw bytes of an incoming or response binary body" do
      profile = Profiler::Models::Profile.new
      processed = profile.send(:process_body, "\x00\x01#{secret}\xFF".b, "application/octet-stream")

      expect(processed[:encoding]).to eq("base64")
      expect(decoded(processed)).not_to include(secret)
      expect(decoded(processed)).to include(Profiler::Redaction::MASK)
    end

    it "masks the raw bytes of an outbound binary body" do
      processed = Profiler::Instrumentation::NetHttpInstrumentation.process_body("\x89PNG#{secret}".b, "image/png")

      expect(processed[:encoding]).to eq("base64")
      expect(decoded(processed)).not_to include(secret)
    end
  end

  describe "which secret is masked" do
    it "masks nothing for a secret the cluster ignores (shorter than 32 characters)" do
      %w[true localhost / abcdefghijklmnopqrstuvwxyz01234].each do |weak|
        Profiler.configuration.cluster_secret = weak
        expect(Profiler::Redaction.filter_hash("a" => weak, "b" => "x #{weak} y")).to eq("a" => weak, "b" => "x #{weak} y")
      end
    end

    it "masks a usable secret even with spaces around it in the configuration" do
      Profiler.configuration.cluster_secret = "  #{secret}\n"
      expect(Profiler::Redaction.filter_hash("a" => secret)).to eq("a" => Profiler::Redaction::MASK)
    end
  end
end
