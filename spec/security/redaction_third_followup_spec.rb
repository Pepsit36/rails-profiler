# frozen_string_literal: true

require "spec_helper"
require "profiler/collectors/mailer_collector"
require "profiler/job_profiler"

# Regression specs for SEC-03, from the third review of the fix: procs of
# filter_parameters applied to named values.
RSpec.describe "Sensitive data redaction, third review follow-up" do
  let(:mask) { Profiler::Redaction::MASK }

  def fake_rails(filters)
    config = Struct.new(:filter_parameters).new(filters)
    Struct.new(:application, :logger).new(Struct.new(:config).new(config), nil)
  end

  # The style of the Rails guide: reversing twice gives the value back.
  let(:involutive) { ->(key, value) { value.reverse! if key.to_s =~ /card[-_]?number/i } }

  # An object whose copies can be counted, as an Active Record model whose
  # after_initialize callbacks run on dup.
  let(:copyable) do
    Class.new do
      class << self
        attr_accessor :copies
      end
      self.copies = 0

      def initialize_copy(_source)
        super
        self.class.copies += 1
      end

      def inspect = "#<User id: 7>"
    end
  end

  def mail_with(args, mailer_method)
    stub_const("CardMailer", Class.new { define_method(:notify, &mailer_method) })
    Profiler.configure { |c| c.track_mailers = true }
    profile = build_profile
    collector = Profiler::Collectors::MailerCollector.new(profile)
    collector.subscribe
    ActiveSupport::Notifications.instrument("process.action_mailer", mailer: "CardMailer", action: "notify", args: args)
    ActiveSupport::Notifications.instrument("deliver.action_mailer",
      mailer_class: "CardMailer", subject: "Card", to: ["a@b.c"], from: ["n@b.c"],
      message_id: "<m@b.c>", perform_deliveries: true, mail: nil)
    collector.collect
    profile.collector_data("mailer")[:emails].first["assigns"]
  end

  describe "a proc applied once per value" do
    before { stub_const("Rails", fake_rails([:password, involutive])) }

    it "rewrites a header once, not under both of its names" do
      expect(Profiler::Redaction.filter_headers("Card-Number" => "4111222233334444"))
        .to eq("Card-Number" => "4444333322221114")
    end

    it "rewrites a value inside a hash passed to a mailer once" do
      assigns = mail_with([{ card_number: "4111222233334444" }], ->(options) {})

      expect(assigns["options"]).to include("4444333322221114")
    end

    it "rewrites a named mailer argument once" do
      assigns = mail_with(["4111222233334444"], ->(card_number) {})

      expect(assigns["card_number"]).to eq('"4444333322221114"')
    end
  end

  describe "objects that are not strings" do
    before { stub_const("Rails", fake_rails([:password, involutive])) }

    it "are not copied when passed to a mailer" do
      user = copyable.new
      assigns = mail_with([user], ->(user) {})

      expect(copyable.copies).to eq(0)
      expect(assigns["user"]).to eq("#<User id: 7>")
    end

    it "are not copied inside a hash passed to a job" do
      Profiler.configure do |c|
        c.enabled = true
        c.track_jobs = true
        c.track_memory = false
        c.track_http = false
      end
      Profiler.instance_variable_set(:@storage, Profiler::Storage::MemoryStore.new)
      user = copyable.new
      Profiler::JobProfiler.profile(job_class: "CardJob", job_id: "j1", queue: "default",
                                    arguments: [{ "user" => user, "password" => "p" }], executions: 0) {}

      expect(copyable.copies).to eq(0)
      arguments = Profiler.storage.list.first.collector_data("job")["arguments"]
      expect(arguments.first).to include("#<User id: 7>").and include(mask)
    end
  end

  describe "a filtered JSON body that cannot be generated back" do
    it "is labelled unparseable without logging a failure" do
      expect(Profiler).not_to receive(:log)
      raw = '{"password":"x","n":NaN}'
      allow(JSON).to receive(:parse).and_call_original
      allow(JSON).to receive(:parse).with(raw).and_return("password" => "x", "n" => Float::NAN)

      expect(Profiler::Redaction.filter_body(raw, "application/json")).to start_with("[FILTERED: unparseable")
    end
  end
end
