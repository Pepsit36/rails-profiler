# frozen_string_literal: true

require_relative "base_collector"

module Profiler
  module Collectors
    class MailerCollector < BaseCollector
      MAX_EMAILS = 50
      MAX_BODY_SIZE = 100 * 1024 # 100 KB

      def initialize(profile)
        super
        @emails = []
        @errors = []
        @queued = []
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

        # Capture the subscriber thread so notifications from other threads (e.g. async
        # job threads delivering mail enqueued via deliver_later) are ignored by this collector.
        @subscriber_thread = Thread.current

        # Use a stack so multiple deliver_later calls in the same request are all tracked.
        claim_thread_slot(:profiler_pending_processes, [])

        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("process.action_mailer") do |_name, started, finished, _id, payload|
          next unless Thread.current.equal?(@subscriber_thread)
          next if rails_preview_request?

          mailer_class = payload[:mailer].to_s
          action = payload[:action].to_s
          (Thread.current[:profiler_pending_processes] ||= []) << {
            mailer_class: mailer_class,
            action: action,
            duration_ms: ((finished - started) * 1000).round(2),
            assigns: extract_assigns(mailer_class, action, payload[:args])
          }
        end

        @subscriptions << ActiveSupport::Notifications.monotonic_subscribe("deliver.action_mailer") do |_name, started, finished, _id, payload|
          next unless Thread.current.equal?(@subscriber_thread)
          next unless payload[:perform_deliveries]
          next if rails_preview_request?

          delivery_ms = ((finished - started) * 1000).round(2)
          process_info = (Thread.current[:profiler_pending_processes] ||= []).pop || {}
          mail = payload[:mail]

          mailer_class = process_info[:mailer_class] || payload[:mailer_class].to_s
          action = process_info[:action].to_s
          config = Profiler.configuration
          next if config.mailer_skip_actions.any? { |a| a == "#{mailer_class}##{action}" || a == mailer_class }

          delivery_mode = mail_delivery_job? ? "deliver_later" : "deliver_now"
          email = build_email_record(payload, mail, process_info, delivery_ms, delivery_mode)
          email[:error] ? @errors << email : @emails << email
        rescue StandardError => e
          @errors << { error: e.message, triggered_at: Time.now.utc.iso8601(3) }
        end
      end

      def collect
        # Any remaining pending process entries had no matching deliver event:
        # they were enqueued via deliver_later in the HTTP context.
        pending = Thread.current[:profiler_pending_processes] || []
        unsubscribe

        pending.each do |info|
          @queued << {
            mailer_class: info[:mailer_class],
            action: info[:action],
            delivery_mode: "deliver_later",
            delivery_method: extract_delivery_method,
            duration_ms: info[:duration_ms],
            assigns: info[:assigns],
            body_captured: false,
            triggered_at: Time.now.utc.iso8601(3)
          }
        end

        detect_loops

        truncated = @emails.size > MAX_EMAILS
        emails = @emails.first(MAX_EMAILS)

        store_data(
          emails: emails.map { |e| e.transform_keys(&:to_s) },
          errors: @errors.map { |e| e.transform_keys(&:to_s) },
          queued: @queued.map { |e| e.transform_keys(&:to_s) },
          loop_warnings: @loop_warnings.map { |w| w.transform_keys(&:to_s) },
          total: @emails.size + @errors.size,
          queued_count: @queued.size,
          deliver_now: @emails.count { |e| e[:delivery_mode] == "deliver_now" },
          deliver_later: @emails.count { |e| e[:delivery_mode] == "deliver_later" },
          multi_part_count: @emails.count { |e| e[:parts]&.size.to_i > 1 },
          failed: @errors.size,
          truncated: truncated
        )
      end

      def unsubscribe
        unsubscribe_notifications(@subscriptions)
        restore_thread_slots
      end

      def has_data?
        @emails.any? || @errors.any? || @queued.any?
      end

      def toolbar_summary
        total = @emails.size + @errors.size
        queued = @queued.size
        return { text: "0 emails", color: "gray" } if total == 0 && queued == 0

        now_count = @emails.count { |e| e[:delivery_mode] == "deliver_now" }
        later_count = @emails.count { |e| e[:delivery_mode] == "deliver_later" }
        has_errors = @errors.any? || @loop_warnings.any?

        parts = []
        parts << "#{now_count} now" if now_count > 0
        parts << "#{later_count} later" if later_count > 0
        parts << "#{queued} queued" if queued > 0
        detail = parts.any? ? " (#{parts.join(" · ")})" : ""

        text = "#{total + queued} email#{(total + queued) > 1 ? "s" : ""}#{detail}"
        text += " ⚠️ #{@errors.size} error#{@errors.size > 1 ? "s" : ""}" if @errors.any?

        { text: text, color: has_errors ? "red" : "green" }
      end

      private

      def mail_delivery_job?
        Thread.current[:profiler_current_job_class].to_s.end_with?("MailDeliveryJob")
      end

      def build_email_record(payload, mail, process_info, delivery_ms, delivery_mode = "deliver_now")
        config = Profiler.configuration
        mailer_class = process_info[:mailer_class] || payload[:mailer_class].to_s
        action = process_info[:action]

        # In Rails 7+, payload[:mail] is the encoded string (mail.encoded), not a Mail::Message.
        # Parse it only for attributes not available in the payload (parts, attachments, reply_to, body).
        mail_obj = parse_mail(mail)

        to_list = sanitize_recipients(Array(payload[:to]), config)
        body_html, body_text = config.capture_mail_body ? extract_body(mail_obj) : [nil, nil]

        {
          mailer_class: mailer_class,
          action: action,
          subject: payload[:subject],
          to: to_list,
          from: Array(payload[:from]),
          cc: Array(payload[:cc]),
          bcc: Array(payload[:bcc]),
          reply_to: Array(mail_obj&.reply_to),
          message_id: payload[:message_id],
          delivery_method: extract_delivery_method,
          delivery_mode: delivery_mode,
          duration_ms: process_info[:duration_ms],
          delivery_ms: delivery_ms,
          parts: extract_parts(mail_obj),
          attachments: extract_attachments(mail_obj),
          template: action ? "#{to_path(mailer_class)}/#{action}" : nil,
          assigns: process_info[:assigns] || {},
          body_captured: !body_html.nil? || !body_text.nil?,
          body_html: body_html,
          body_text: body_text,
          error: nil,
          triggered_at: Time.now.utc.iso8601(3)
        }
      end

      def extract_assigns(mailer_class, action, args)
        return {} if action.nil? || action.empty? || args.nil?

        klass = Object.const_get(mailer_class)
        params = klass.instance_method(action).parameters
        params.each_with_index.each_with_object({}) do |((_, name), i), h|
          h[name.to_s] = if Profiler::Redaction.sensitive_key?(name)
            Profiler::Redaction::MASK
          else
            value = args[i]
            # A hash or array goes through the filter by its keys, anything
            # else by the parameter name: never both, so a proc runs once.
            filtered = if value.is_a?(Hash) || value.is_a?(Array)
              Profiler::Redaction.filter_value(value)
            else
              Profiler::Redaction.filter_named(name, value)
            end
            serialize_assign(filtered)
          end
        end
      rescue StandardError
        {}
      end

      def extract_body(mail)
        return [nil, nil] unless mail.respond_to?(:multipart?)

        html = text = nil
        if mail.multipart?
          html_part = mail.parts.find { |p| p.content_type.to_s.start_with?("text/html") }
          text_part = mail.parts.find { |p| p.content_type.to_s.start_with?("text/plain") }
          html = html_part&.body&.decoded&.then { |b| Profiler::Redaction.truncate(b, MAX_BODY_SIZE, "") }
          text = text_part&.body&.decoded&.then { |b| Profiler::Redaction.truncate(b, MAX_BODY_SIZE, "") }
        elsif mail.content_type.to_s.start_with?("text/html")
          html = Profiler::Redaction.truncate(mail.body.decoded, MAX_BODY_SIZE, "")
        else
          text = Profiler::Redaction.truncate(mail.body.decoded, MAX_BODY_SIZE, "")
        end
        [html.nil? || html.empty? ? nil : html, text.nil? || text.empty? ? nil : text]
      rescue StandardError
        [nil, nil]
      end

      def serialize_assign(value)
        return "nil" if value.nil?

        inspected = value.inspect
        Profiler::Redaction.truncate(inspected, 300, "…")
      rescue StandardError
        value.to_s
      end

      def parse_mail(mail)
        return mail if mail.respond_to?(:multipart?)
        return nil unless mail.is_a?(String)

        Mail.new(mail)
      rescue StandardError
        nil
      end

      def sanitize_recipients(recipients, config)
        return recipients unless config.respond_to?(:sanitize_mailer_recipients) && config.sanitize_mailer_recipients

        recipients.map do |addr|
          local, domain = addr.to_s.split("@", 2)
          domain ? "#{local[0]}***@#{domain.gsub(/[^.]+(?=\.)/, "***")}" : addr
        end
      end

      def extract_delivery_method
        return "unknown" unless defined?(ActionMailer::Base)

        ActionMailer::Base.delivery_method.to_s
      rescue StandardError
        "unknown"
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
            "filename" => att.filename.to_s,
            "size" => att.body.decoded.bytesize
          }
        rescue StandardError
          { "filename" => att.filename.to_s, "size" => 0 }
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
