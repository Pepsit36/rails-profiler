# frozen_string_literal: true

require "spec_helper"

RSpec.describe Profiler::Collectors::MailerCollector do
  let(:profile) { build_profile }
  subject(:collector) { described_class.new(profile) }

  def fire_process_event(mailer: "UserMailer", action: "welcome_email")
    ActiveSupport::Notifications.instrument("process.action_mailer",
      mailer: mailer, action: action, args: [])
  end

  def fire_deliver_event(mailer_class: "UserMailer", subject: "Hello", to: ["user@example.com"],
                         from: ["app@example.com"], message_id: "<abc@mail.com>",
                         perform_deliveries: true, mail: nil)
    ActiveSupport::Notifications.instrument("deliver.action_mailer",
      mailer_class: mailer_class,
      subject: subject,
      to: to,
      from: from,
      message_id: message_id,
      perform_deliveries: perform_deliveries,
      mail: mail)
  end

  before do
    Profiler.configure { |c| c.track_mailers = true }
  end

  describe "#name" do
    it { expect(collector.name).to eq("mailer") }
  end

  describe "#icon" do
    it { expect(collector.icon).to eq("✉️") }
  end

  describe "#priority" do
    it { expect(collector.priority).to eq(45) }
  end

  describe "#subscribe and #collect" do
    context "with a deliver_now email" do
      it "captures deliver.action_mailer event" do
        collector.subscribe
        fire_process_event
        fire_deliver_event

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:total]).to eq(1)
        expect(data[:deliver_now]).to eq(1)
        expect(data[:deliver_later]).to eq(0)
        expect(data[:failed]).to eq(0)
        expect(data[:emails].size).to eq(1)
      end

      it "captures subject, to, from from the event" do
        collector.subscribe
        fire_process_event(mailer: "UserMailer", action: "welcome_email")
        fire_deliver_event(
          mailer_class: "UserMailer",
          subject: "Welcome!",
          to: ["user@example.com"],
          from: ["no-reply@app.com"]
        )

        collector.collect
        data = profile.collector_data("mailer")
        email = data[:emails].first

        expect(email["subject"]).to eq("Welcome!")
        expect(email["to"]).to eq(["user@example.com"])
        expect(email["from"]).to eq(["no-reply@app.com"])
        expect(email["mailer_class"]).to eq("UserMailer")
        expect(email["action"]).to eq("welcome_email")
      end

      it "links process event to deliver event for action name" do
        collector.subscribe
        fire_process_event(mailer: "AdminMailer", action: "alert_email")
        fire_deliver_event(mailer_class: "AdminMailer")

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:emails].first["action"]).to eq("alert_email")
      end
    end

    context "without perform_deliveries" do
      it "skips the event" do
        collector.subscribe
        fire_deliver_event(perform_deliveries: false)

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:total]).to eq(0)
      end
    end

    context "with multiple emails" do
      it "captures all emails" do
        collector.subscribe
        3.times do |i|
          fire_process_event(mailer: "UserMailer", action: "email_#{i}")
          fire_deliver_event(mailer_class: "UserMailer", subject: "Email #{i}", to: ["u#{i}@example.com"])
        end

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:total]).to eq(3)
        expect(data[:emails].size).to eq(3)
      end
    end

    context "with multi-part mail" do
      it "extracts parts list" do
        part_html = double("part", content_type: "text/html; charset=utf-8")
        part_text = double("part", content_type: "text/plain")
        mail_obj = double("mail",
          multipart?: true,
          parts: [part_html, part_text],
          cc: nil, reply_to: nil,
          delivery_method: nil,
          message_id: "<multi@mail>",
          subject: "Multi",
          to: ["u@example.com"],
          from: ["a@example.com"],
          attachments: []
        )

        collector.subscribe
        fire_process_event
        fire_deliver_event(mail: mail_obj, subject: "Multi", to: ["u@example.com"])

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:emails].first["parts"]).to eq(["text/html", "text/plain"])
        expect(data[:multi_part_count]).to eq(1)
      end
    end

    context "with attachments" do
      it "captures filename and size" do
        att_body = double("body", decoded: "x" * 1024)
        att = double("attachment", filename: "invoice.pdf", body: att_body)
        mail_obj = double("mail",
          multipart?: false,
          content_type: "text/plain",
          parts: [],
          cc: nil, reply_to: nil,
          delivery_method: nil,
          message_id: nil,
          subject: nil, to: nil, from: nil,
          attachments: [att]
        )

        collector.subscribe
        fire_process_event
        fire_deliver_event(mail: mail_obj)

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:emails].first["attachments"]).to eq([{ "filename" => "invoice.pdf", "size" => 1024 }])
      end
    end

    context "loop detection" do
      it "adds loop warning when same mailer#action > 3 times" do
        collector.subscribe
        4.times do
          fire_process_event(mailer: "UserMailer", action: "welcome_email")
          fire_deliver_event(mailer_class: "UserMailer")
        end

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:loop_warnings].size).to eq(1)
        expect(data[:loop_warnings].first["key"]).to eq("UserMailer#welcome_email")
        expect(data[:loop_warnings].first["count"]).to eq(4)
      end

      it "does not warn when <= 3 deliveries of same type" do
        collector.subscribe
        3.times do
          fire_process_event
          fire_deliver_event
        end

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:loop_warnings]).to be_empty
      end
    end

    context "truncation at MAX_EMAILS" do
      it "truncates to MAX_EMAILS and sets truncated flag" do
        stub_const("Profiler::Collectors::MailerCollector::MAX_EMAILS", 3)

        collector.subscribe
        5.times do |i|
          fire_process_event(mailer: "UserMailer", action: "email_#{i}")
          fire_deliver_event(mailer_class: "UserMailer")
        end

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:emails].size).to eq(3)
        expect(data[:truncated]).to be(true)
        expect(data[:total]).to eq(5)
      end
    end

    context "when track_mailers is false" do
      before { Profiler.configure { |c| c.track_mailers = false } }

      it "does not subscribe to notifications" do
        expect(ActiveSupport::Notifications).not_to receive(:monotonic_subscribe)
        collector.subscribe
      end
    end

    context "with preview request" do
      it "ignores process events from Rails preview paths" do
        Thread.current[:profiler_request_path] = "/rails/mailers/user_mailer/welcome_email"

        collector.subscribe
        fire_process_event
        fire_deliver_event

        collector.collect
        data = profile.collector_data("mailer")

        expect(data[:total]).to eq(1)
      ensure
        Thread.current[:profiler_request_path] = nil
      end
    end
  end

  describe "recipient sanitization" do
    before { Profiler.configure { |c| c.track_mailers = true; c.sanitize_mailer_recipients = true } }

    it "masks email addresses when sanitize_mailer_recipients is true" do
      collector.subscribe
      fire_process_event
      fire_deliver_event(to: ["john.doe@example.com"])

      collector.collect
      data = profile.collector_data("mailer")
      to = data[:emails].first["to"]

      expect(to.first).not_to include("john.doe")
      expect(to.first).to include("***")
    end
  end

  describe "#has_data?" do
    it "returns false when no emails" do
      collector.subscribe
      collector.collect
      expect(collector.has_data?).to be(false)
    end

    it "returns true when emails present" do
      collector.subscribe
      fire_process_event
      fire_deliver_event
      collector.collect
      expect(collector.has_data?).to be(true)
    end
  end

  describe "#toolbar_summary" do
    it "returns gray for 0 emails" do
      summary = collector.toolbar_summary
      expect(summary[:color]).to eq("gray")
      expect(summary[:text]).to include("0")
    end

    it "returns green for emails without errors" do
      collector.subscribe
      fire_process_event
      fire_deliver_event
      collector.collect

      summary = collector.toolbar_summary
      expect(summary[:color]).to eq("green")
      expect(summary[:text]).to include("1 email")
    end

    it "shows now/later breakdown in text" do
      collector.subscribe
      fire_process_event
      fire_deliver_event
      collector.collect

      summary = collector.toolbar_summary
      expect(summary[:text]).to include("now")
    end
  end
end
