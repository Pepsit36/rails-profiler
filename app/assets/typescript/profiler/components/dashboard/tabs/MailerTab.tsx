import { useState } from 'preact/hooks'
import { MailerData, MailerEmail } from '../../../dashboard/types'

interface Props {
  mailerData: MailerData | undefined
}

function EmailDetail({ email }: { email: MailerEmail }) {
  return (
    <div class="profiler-query-card" style="margin-top: 8px;">
      <div class="profiler-query-card__header">
        <span class="profiler-text--mono profiler-text--sm">
          {email.mailer_class}#{email.action}
        </span>
        <div class="profiler-flex profiler-flex--gap-2">
          {email.delivery_mode && (
            <span class="badge-info">{email.delivery_mode}</span>
          )}
          {email.delivery_method && (
            <span class="badge-default">{email.delivery_method}</span>
          )}
          {email.error
            ? <span class="badge-error">❌ Error</span>
            : <span class="badge-success">✅ Sent</span>
          }
        </div>
      </div>
      <div class="profiler-query-card__body profiler-text--sm">
        {email.subject && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">Subject</span>
            <span>{email.subject}</span>
          </div>
        )}
        {email.to && email.to.length > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">To</span>
            <span>{email.to.join(', ')}</span>
          </div>
        )}
        {email.from && email.from.length > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">From</span>
            <span>{email.from.join(', ')}</span>
          </div>
        )}
        {email.cc && email.cc.length > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">CC</span>
            <span>{email.cc.join(', ')}</span>
          </div>
        )}
        {email.template && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">Template</span>
            <span class="profiler-text--mono">{email.template}</span>
          </div>
        )}
        {email.parts && email.parts.length > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">Parts</span>
            <span>{email.parts.join(', ')}</span>
          </div>
        )}
        {email.attachments && email.attachments.length > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">Attachments</span>
            <span>{email.attachments.map(a => `${a.filename} (${(a.size / 1024).toFixed(1)} KB)`).join(', ')}</span>
          </div>
        )}
        <div class="profiler-toolbar-panel-row">
          <span class="profiler-text--muted">Render</span>
          <span>{email.duration_ms != null ? `${email.duration_ms} ms` : '-'}</span>
        </div>
        {email.delivery_ms != null && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">Delivery</span>
            <span>{email.delivery_ms} ms</span>
          </div>
        )}
        {email.message_id && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">Message-ID</span>
            <span class="profiler-text--mono profiler-text--xs">{email.message_id}</span>
          </div>
        )}
        {email.error && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">Error</span>
            <span class="profiler-text--error">{email.error}</span>
          </div>
        )}
      </div>
    </div>
  )
}

function EmailRow({ email, onClick, isExpanded }: { email: MailerEmail; onClick: () => void; isExpanded: boolean }) {
  const toStr = email.to && email.to.length > 0
    ? (email.to.slice(0, 2).join(', ') + (email.to.length > 2 ? ', …' : ''))
    : '-'

  return (
    <div
      class="profiler-query-card"
      style={{ cursor: 'pointer', marginBottom: '4px' }}
      onClick={onClick}
    >
      <div class="profiler-query-card__header">
        <span class="profiler-text--sm">
          <strong>{email.mailer_class}</strong>#{email.action}
          {email.subject && <span class="profiler-text--muted"> — {email.subject.slice(0, 50)}{email.subject.length > 50 ? '…' : ''}</span>}
        </span>
        <div class="profiler-flex profiler-flex--gap-2">
          {email.delivery_mode && (
            <span class="badge-info profiler-text--xs">{email.delivery_mode}</span>
          )}
          {email.duration_ms != null && (
            <span class="profiler-text--muted profiler-text--xs">{email.duration_ms} ms</span>
          )}
          {email.error
            ? <span class="badge-error profiler-text--xs">❌</span>
            : <span class="badge-success profiler-text--xs">✅</span>
          }
          <span class="profiler-text--muted profiler-text--xs">{isExpanded ? '▲' : '▼'}</span>
        </div>
      </div>
      {isExpanded && <EmailDetail email={email} />}
    </div>
  )
}

export function MailerTab({ mailerData }: Props) {
  const [expandedIndex, setExpandedIndex] = useState<number | null>(null)
  const [expandedErrorIndex, setExpandedErrorIndex] = useState<number | null>(null)

  if (!mailerData || mailerData.total === 0) {
    return (
      <div class="profiler-empty">
        <p class="profiler-empty__description">No emails sent during this request</p>
      </div>
    )
  }

  const toggleRow = (i: number) => setExpandedIndex(expandedIndex === i ? null : i)
  const toggleErrorRow = (i: number) => setExpandedErrorIndex(expandedErrorIndex === i ? null : i)

  return (
    <>
      <h2 class="profiler-section__header">Mailer Deliveries</h2>

      {/* Stats */}
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Total: <strong>{mailerData.total}</strong></span>
        {mailerData.deliver_now > 0 && (
          <span>deliver_now: <strong>{mailerData.deliver_now}</strong></span>
        )}
        {mailerData.deliver_later > 0 && (
          <span>deliver_later: <strong>{mailerData.deliver_later}</strong></span>
        )}
        {mailerData.multi_part_count > 0 && (
          <span>Multi-part: <strong>{mailerData.multi_part_count}</strong></span>
        )}
        {mailerData.failed > 0 && (
          <span>Errors: <strong class="profiler-text--error">{mailerData.failed}</strong></span>
        )}
      </div>

      {/* Loop warnings */}
      {mailerData.loop_warnings.length > 0 && (
        <div class="profiler-mb-4" style={{ background: 'var(--profiler-warning-bg, rgba(251,191,36,0.1))', border: '1px solid var(--profiler-warning, #f59e0b)', borderRadius: '4px', padding: '12px' }}>
          <strong class="profiler-text--warning">⚠️ Send loop detected</strong>
          {mailerData.loop_warnings.map((w, i) => (
            <div key={i} class="profiler-text--sm profiler-mt-2">{w.message}</div>
          ))}
        </div>
      )}

      {/* Truncation notice */}
      {mailerData.truncated && (
        <div class="profiler-text--warning profiler-text--sm profiler-mb-4">
          ⚠️ Showing first 50 emails only — more were truncated
        </div>
      )}

      {/* Emails */}
      {mailerData.emails.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-4 profiler-mb-3">Emails</h3>
          {mailerData.emails.map((email, i) => (
            <EmailRow
              key={i}
              email={email}
              onClick={() => toggleRow(i)}
              isExpanded={expandedIndex === i}
            />
          ))}
        </>
      )}

      {/* Errors */}
      {mailerData.errors.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-6 profiler-mb-3 profiler-text--error">Delivery Errors</h3>
          {mailerData.errors.map((email, i) => (
            <EmailRow
              key={`err-${i}`}
              email={email}
              onClick={() => toggleErrorRow(i)}
              isExpanded={expandedErrorIndex === i}
            />
          ))}
        </>
      )}
    </>
  )
}
