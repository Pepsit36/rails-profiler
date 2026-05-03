# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class MailerCollector < BaseCollector
      MAX_EMAILS = 50

      def initialize(profile)
        super
        @emails = []
        @errors = []
        @loop_warnings = []
        @subscriptions = []
      end

      def icon
        "✉️"
      end

      def priority
        45
      end

      def tab_config
        {
          key: "mailer",
          label: "Mailers",
          icon: icon,
          priority: priority,
          enabled: true,
          default_active: false
        }
      end

      def subscribe
        return unless defined?(ActiveSupport::Notifications)
        return unless Profiler.configuration.track_mailers

        # Store process event context so deliver event can pick it up
        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("process.action_mailer") do |_name, started, finished, _id, payload|
          next if rails_preview_request?

          Thread.current[:profiler_last_mailer_process] = {
            mailer_class: payload[:mailer].to_s,
            action: payload[:action].to_s,
            duration_ms: ((finished - started) * 1000).round(2)
          }
        end

        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("deliver.action_mailer") do |_name, started, finished, _id, payload|
          next unless payload[:perform_deliveries]

          delivery_ms = ((finished - started) * 1000).round(2)
          process_info = Thread.current.delete(:profiler_last_mailer_process) || {}
          mail = payload[:mail]

          email = build_email_record(payload, mail, process_info, delivery_ms)

          if email[:error]
            @errors << email
          else
            @emails << email
          end
        rescue StandardError => e
          @errors << { error: e.message, triggered_at: Time.now.utc.iso8601(3) }
        end
      end

      def collect
        Thread.current.delete(:profiler_last_mailer_process)

        @subscriptions.each { |sub| ActiveSupport::Notifications.unsubscribe(sub) }

        detect_loops

        truncated = @emails.size > MAX_EMAILS
        emails = @emails.first(MAX_EMAILS)

        store_data(
          emails: emails.map { |e| e.transform_keys(&:to_s) },
          errors: @errors.map { |e| e.transform_keys(&:to_s) },
          loop_warnings: @loop_warnings,
          total: @emails.size,
          deliver_now: @emails.count { |e| e[:delivery_mode] == "deliver_now" },
          deliver_later: @emails.count { |e| e[:delivery_mode] == "deliver_later" },
          multi_part_count: @emails.count { |e| e[:parts]&.size.to_i > 1 },
          failed: @errors.size,
          truncated: truncated
        )
      end

      def has_data?
        @emails.any? || @errors.any?
      end

      def toolbar_summary
        total = @emails.size + @errors.size
        return { text: "0 emails", color: "gray" } if total == 0

        now_count = @emails.count { |e| e[:delivery_mode] == "deliver_now" }
        later_count = @emails.count { |e| e[:delivery_mode] == "deliver_later" }
        has_errors = @errors.any? || @loop_warnings.any?

        parts = []
        parts << "#{now_count} now" if now_count > 0
        parts << "#{later_count} later" if later_count > 0
        detail = parts.any? ? " (#{parts.join(" · ")})" : ""

        text = "#{total} email#{total > 1 ? "s" : ""}#{detail}"
        text += " ⚠️ #{@errors.size} error#{@errors.size > 1 ? "s" : ""}" if @errors.any?

        { text: text, color: has_errors ? "red" : "green" }
      end

      private

      def build_email_record(payload, mail, process_info, delivery_ms)
        config = Profiler.configuration
        mailer_class = process_info[:mailer_class] || payload[:mailer_class].to_s
        action = process_info[:action]

        to_list = sanitize_recipients(Array(payload[:to] || mail&.to), config)

        {
          mailer_class: mailer_class,
          action: action,
          subject: payload[:subject] || mail&.subject,
          to: to_list,
          from: Array(payload[:from] || mail&.from),
          cc: Array(mail&.cc),
          bcc: [],
          reply_to: Array(mail&.reply_to),
          message_id: payload[:message_id] || mail&.message_id,
          delivery_method: extract_delivery_method(mail),
          delivery_mode: "deliver_now",
          duration_ms: process_info[:duration_ms],
          delivery_ms: delivery_ms,
          parts: extract_parts(mail),
          attachments: extract_attachments(mail),
          template: action ? "#{to_path(mailer_class)}/#{action}" : nil,
          body_captured: false,
          body_html: nil,
          body_text: nil,
          error: nil,
          triggered_at: Time.now.utc.iso8601(3)
        }
      end

      def sanitize_recipients(recipients, config)
        return recipients unless config.respond_to?(:sanitize_mailer_recipients) && config.sanitize_mailer_recipients

        recipients.map do |addr|
          local, domain = addr.to_s.split("@", 2)
          domain ? "#{local[0]}***@#{domain.gsub(/[^.]+(?=\.)/, "***")}" : addr
        end
      end

      def extract_delivery_method(mail)
        return "unknown" unless mail

        klass = mail.delivery_method&.class&.name || ""
        klass.split("::").last&.gsub(/([A-Z])/) { "_#{$1.downcase}" }&.sub(/\A_/, "") || "unknown"
      end

      def extract_parts(mail)
        return [] unless mail

        if mail.multipart?
          mail.parts.map { |p| p.content_type.to_s.split(";").first }
        elsif mail.content_type
          [mail.content_type.to_s.split(";").first]
        else
          []
        end
      end

      def extract_attachments(mail)
        return [] unless mail

        (mail.attachments || []).map do |att|
          {
            filename: att.filename.to_s,
            size: att.body.decoded.bytesize
          }
        rescue StandardError
          { filename: att.filename.to_s, size: 0 }
        end
      end

      def detect_loops
        counts = Hash.new(0)
        @emails.each { |e| counts["#{e[:mailer_class]}##{e[:action]}"] += 1 }

        counts.each do |key, count|
          next unless count > 3

          @loop_warnings << {
            key: key,
            count: count,
            message: "#{key} was called #{count} times in a single request — possible send loop"
          }
        end
      end

      def rails_preview_request?
        path = Thread.current[:profiler_request_path]
        path&.start_with?("/rails/mailers")
      end

      def to_path(class_name)
        class_name.to_s
                  .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                  .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                  .downcase
      end
    end
  end
end
