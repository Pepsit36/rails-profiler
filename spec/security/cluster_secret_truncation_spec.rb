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
  # code (collectors and the job, console and test profilers) must not cut text by itself.
  it "leaves no raw cut of text in the capture code" do
    root = File.expand_path("../../lib/profiler", __dir__)
    files = Dir[File.join(root, "collectors", "*.rb")] + Dir[File.join(root, "*_profiler.rb")]
    raw_cut = /\[0,\s*[\w:]+\]|\.slice\(\s*0\s*,|\.byteslice\(\s*0\s*,/
    offenders = files.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, i|
        "#{File.basename(file)}:#{i + 1}: #{line.strip}" if line.match?(raw_cut) && !line.include?("Redaction.truncate")
      end
    end

    expect(offenders).to eq([])
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

    it "gives the whole output, masked, once the run is over" do
      each_offset do |run, text|
        store.update(run.id, status: "passed", finished_at: Time.now)
        full = store.find(run.id).to_h[:output]

        expect(leaks?(full)).to be(false)
        expect(full).to eq(text.sub(secret, Profiler::Redaction::MASK))
      end
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
