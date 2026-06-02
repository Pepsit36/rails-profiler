# frozen_string_literal: true

module Profiler
  module MCP
    module Tools
      class GetProfileMailers
        SEVERITY_ICONS = { "deliver_now" => "✅", "deliver_later" => "📬", "queued" => "⏳" }.freeze

        def self.call(params)
          token = params["token"]
          unless token
            return [{ type: "text", text: "Error: token parameter is required" }]
          end

          profile = if token == "latest"
            Profiler.storage.list(limit: 1).first
          else
            Profiler.storage.load(token)
          end
          unless profile
            return [{ type: "text", text: "Profile not found: #{token}" }]
          end

          mailer_data = profile.collector_data("mailer")
          unless mailer_data && mailer_data["total"].to_i + mailer_data["queued_count"].to_i > 0
            return [{ type: "text", text: "No mailer activity found in this profile" }]
          end

          [{ type: "text", text: format_mailers(profile, mailer_data, params) }]
        end

        private

        def self.format_mailers(profile, mailer_data, params)
          mailer_filter = params["mailer_class"]&.downcase
          action_filter = params["action"]&.downcase
          mode_filter   = params["delivery_mode"]

          emails  = filter_entries(mailer_data["emails"]  || [], mailer_filter, action_filter, mode_filter)
          errors  = filter_entries(mailer_data["errors"]  || [], mailer_filter, action_filter, mode_filter)
          queued  = filter_entries(mailer_data["queued"]  || [], mailer_filter, action_filter, mode_filter)

          lines = []
          lines << "# Mailer Activity: #{profile.token}\n"
          lines << "**Request:** #{profile.method} #{profile.path}"
          lines << "**Delivered:** #{mailer_data['total']} email(s)"
          lines << "**Queued (deliver_later):** #{mailer_data['queued_count']} email(s)"
          lines << "**Errors:** #{mailer_data['failed']}"
          lines << "**Body captured:** #{mailer_data.dig('emails', 0, 'body_captured') ? 'yes' : 'no (set capture_mail_body: true)'}"

          loop_warnings = mailer_data["loop_warnings"] || []
          if loop_warnings.any?
            lines << ""
            lines << "⚠️ **Loop warnings:**"
            loop_warnings.each { |w| lines << "  - #{w['message']}" }
          end

          append_email_section(lines, "Delivered Emails", emails, profile, params) if emails.any?
          append_email_section(lines, "Errors", errors, profile, params) if errors.any?
          append_queued_section(lines, queued) if queued.any?

          lines.join("\n")
        end

        def self.filter_entries(entries, mailer_filter, action_filter, mode_filter)
          entries = entries.select { |e| e["mailer_class"].to_s.downcase.include?(mailer_filter) } if mailer_filter
          entries = entries.select { |e| e["action"].to_s.downcase.include?(action_filter) }       if action_filter
          entries = entries.select { |e| e["delivery_mode"].to_s == mode_filter }                  if mode_filter
          entries
        end

        def self.append_email_section(lines, title, emails, profile, params)
          lines << ""
          lines << "## #{title}\n"

          emails.each_with_index do |email, i|
            lines << "### Email #{i + 1}: #{email['mailer_class']}##{email['action']}"
            lines << "- **Subject:** #{email['subject']}"
            lines << "- **To:** #{Array(email['to']).join(', ')}"
            lines << "- **From:** #{Array(email['from']).join(', ')}"
            lines << "- **CC:** #{Array(email['cc']).join(', ')}"          unless Array(email['cc']).empty?
            lines << "- **BCC:** #{Array(email['bcc']).join(', ')}"        unless Array(email['bcc']).empty?
            lines << "- **Reply-To:** #{Array(email['reply_to']).join(', ')}" unless Array(email['reply_to']).empty?
            lines << "- **Message-ID:** #{email['message_id']}"            if email['message_id']
            lines << "- **Delivery method:** #{email['delivery_method']}"
            lines << "- **Mode:** #{email['delivery_mode']}"
            lines << "- **Render duration:** #{email['duration_ms']}ms"    if email['duration_ms']
            lines << "- **Delivery duration:** #{email['delivery_ms']}ms"  if email['delivery_ms']
            lines << "- **Error:** #{email['error']}"                      if email['error']

            parts = Array(email['parts'])
            lines << "- **Parts:** #{parts.join(', ')}" if parts.any?

            attachments = Array(email['attachments'])
            if attachments.any?
              lines << "- **Attachments:**"
              attachments.each { |a| lines << "  - #{a['filename']} (#{a['size']} bytes)" }
            end

            assigns = email['assigns'] || {}
            if assigns.any?
              lines << "- **Template assigns:**"
              assigns.each { |k, v| lines << "  - `#{k}`: #{v}" }
            end

            if email['body_captured']
              if email['body_html'] && !email['body_html'].empty?
                lines << "- **HTML body:**"
                formatted = BodyFormatter.format_body(
                  profile.token, "mailer_#{i}_html", email['body_html'], nil, params
                )
                lines << formatted if formatted
              end
              if email['body_text'] && !email['body_text'].empty?
                lines << "- **Text body:**"
                formatted = BodyFormatter.format_body(
                  profile.token, "mailer_#{i}_text", email['body_text'], nil, params
                )
                lines << formatted if formatted
              end
            else
              lines << "- **Body:** not captured (enable `capture_mail_body: true` in initializer)"
            end

            lines << ""
          end
        end

        def self.append_queued_section(lines, queued)
          lines << ""
          lines << "## Queued (deliver_later)\n"
          queued.each_with_index do |email, i|
            lines << "### Queued #{i + 1}: #{email['mailer_class']}##{email['action']}"
            lines << "- **Delivery method:** #{email['delivery_method']}"
            lines << "- **Render duration:** #{email['duration_ms']}ms" if email['duration_ms']
            assigns = email['assigns'] || {}
            if assigns.any?
              lines << "- **Template assigns:**"
              assigns.each { |k, v| lines << "  - `#{k}`: #{v}" }
            end
            lines << ""
          end
        end
      end
    end
  end
end
