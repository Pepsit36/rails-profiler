import { useState } from 'preact/hooks'
import { MailerData, MailerEmail } from '../../../dashboard/types'

interface Props {
  mailerData: MailerData | undefined
}

type BodyMode = 'preview' | 'source' | 'text'

// ── BODY PREVIEW ──────────────────────────────────────────────────────────────

function BodyPreview({ email }: { email: MailerEmail }) {
  const hasHtml = !!email.body_html
  const hasText = !!email.body_text

  if (!email.body_captured) {
    return (
      <div class="profiler-mt-3 profiler-text--xs profiler-text--muted">
        Body not captured — enable <code>config.capture_mail_body = true</code> in your profiler initializer
      </div>
    )
  }

  if (!hasHtml && !hasText) return null

  const [mode, setMode] = useState<BodyMode>(hasHtml ? 'preview' : 'text')

  const switchMode = (m: BodyMode) => (e: MouseEvent) => { e.stopPropagation(); setMode(m) }
  const activeStyle = { borderColor: 'var(--profiler-accent)', color: 'var(--profiler-accent)' }

  return (
    <div class="profiler-mt-3">
      <div class="profiler-mb-2 profiler-flex profiler-flex--gap-2" style={{ alignItems: 'center' }}>
        <span class="profiler-text--muted profiler-text--xs">Body</span>
        {hasHtml && (
          <>
            <button class="profiler-btn profiler-btn--sm" style={mode === 'preview' ? activeStyle : {}} onClick={switchMode('preview')}>
              HTML preview
            </button>
            <button class="profiler-btn profiler-btn--sm" style={mode === 'source' ? activeStyle : {}} onClick={switchMode('source')}>
              HTML source
            </button>
          </>
        )}
        {hasText && (
          <button class="profiler-btn profiler-btn--sm" style={mode === 'text' ? activeStyle : {}} onClick={switchMode('text')}>
            Plain text
          </button>
        )}
      </div>
      {mode === 'preview' && hasHtml && (
        <iframe
          srcdoc={email.body_html ?? undefined}
          // An empty sandbox: no script, and an opaque origin rather than the profiler's.
          sandbox=""
          style={{ width: '100%', height: '300px', border: '1px solid var(--profiler-border)', borderRadius: 'var(--profiler-radius-md)', background: '#fff', display: 'block' }}
        />
      )}
      {(mode === 'source' || mode === 'text') && (
        <pre style={{ maxHeight: '300px', overflow: 'auto', background: 'var(--profiler-bg-lighter, rgba(0,0,0,0.2))', padding: '12px', borderRadius: 'var(--profiler-radius-md)', fontSize: '12px', margin: 0, whiteSpace: 'pre-wrap', wordBreak: 'break-all', border: '1px solid var(--profiler-border)' }}>
          {mode === 'source' ? email.body_html : email.body_text}
        </pre>
      )}
    </div>
  )
}

// ── ASSIGNS ───────────────────────────────────────────────────────────────────

function AssignsSection({ assigns }: { assigns: Record<string, string> }) {
  const entries = Object.entries(assigns)
  if (entries.length === 0) return null

  return (
    <div class="profiler-mt-3">
      <div class="profiler-text--xs profiler-text--muted profiler-mb-1" style={{ textTransform: 'uppercase', letterSpacing: '0.05em' }}>Variables</div>
      {entries.map(([key, value]) => (
        <div key={key} class="profiler-kv-row">
          <span><code>@{key}</code></span>
          <code style={{ textAlign: 'right', wordBreak: 'break-all', maxWidth: '60%' }}>{value}</code>
        </div>
      ))}
    </div>
  )
}

// ── EMAIL DETAIL (expanded) ───────────────────────────────────────────────────

function EmailDetail({ email }: { email: MailerEmail }) {
  return (
    <div class="profiler-mt-3" onClick={(e: MouseEvent) => e.stopPropagation()}>
      {email.subject && (
        <div class="profiler-kv-row"><span>Subject</span><span>{email.subject}</span></div>
      )}
      {email.to && email.to.length > 0 && (
        <div class="profiler-kv-row"><span>To</span><span style={{ textAlign: 'right', wordBreak: 'break-all' }}>{email.to.join(', ')}</span></div>
      )}
      {email.from && email.from.length > 0 && (
        <div class="profiler-kv-row"><span>From</span><span style={{ textAlign: 'right' }}>{email.from.join(', ')}</span></div>
      )}
      {email.cc && email.cc.length > 0 && (
        <div class="profiler-kv-row"><span>CC</span><span style={{ textAlign: 'right' }}>{email.cc.join(', ')}</span></div>
      )}
      {email.bcc && email.bcc.length > 0 && (
        <div class="profiler-kv-row"><span>BCC</span><span style={{ textAlign: 'right' }}>{email.bcc.join(', ')}</span></div>
      )}
      {email.reply_to && email.reply_to.length > 0 && (
        <div class="profiler-kv-row"><span>Reply-To</span><span style={{ textAlign: 'right' }}>{email.reply_to.join(', ')}</span></div>
      )}
      {email.template && (
        <div class="profiler-kv-row"><span>Template</span><code>{email.template}</code></div>
      )}
      {email.parts && email.parts.length > 0 && (
        <div class="profiler-kv-row"><span>Parts</span><span style={{ textAlign: 'right' }}>{email.parts.join(', ')}</span></div>
      )}
      {(email as any).attachments && (email as any).attachments.length > 0 && (
        <div class="profiler-kv-row">
          <span>Attachments</span>
          <span style={{ textAlign: 'right' }}>{(email as any).attachments.map((a: { filename: string; size: number }) => `${a.filename} (${(a.size / 1024).toFixed(1)} KB)`).join(', ')}</span>
        </div>
      )}
      <div class="profiler-kv-row">
        <span>Render</span>
        <span class="profiler-query-card__duration">{email.duration_ms != null ? `${email.duration_ms} ms` : '—'}</span>
      </div>
      {email.delivery_ms != null && (
        <div class="profiler-kv-row"><span>Delivery</span><span class="profiler-query-card__duration">{email.delivery_ms} ms</span></div>
      )}
      {email.message_id && (
        <div class="profiler-kv-row"><span>Message-ID</span><code style={{ fontSize: '11px', wordBreak: 'break-all', maxWidth: '70%', textAlign: 'right' }}>{email.message_id}</code></div>
      )}
      {email.error && (
        <div class="profiler-kv-row"><span>Error</span><span class="profiler-text--error" style={{ textAlign: 'right' }}>{email.error}</span></div>
      )}
      {email.assigns && Object.keys(email.assigns).length > 0 && (
        <AssignsSection assigns={email.assigns} />
      )}
      <BodyPreview email={email} />
    </div>
  )
}

// ── EMAIL ROW ─────────────────────────────────────────────────────────────────

function EmailRow({ email, onClick, isExpanded }: { email: MailerEmail; onClick: () => void; isExpanded: boolean }) {
  const cardClass = ['profiler-query-card', email.error ? 'profiler-query-card--slow' : ''].filter(Boolean).join(' ')

  return (
    <div class={cardClass} style={{ cursor: 'pointer', marginBottom: '6px' }} onClick={onClick}>
      <div class="profiler-query-card__header">
        <div class="profiler-flex profiler-flex--gap-2" style={{ minWidth: 0, flex: 1 }}>
          <span class="profiler-text--sm" style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
            <strong>{email.mailer_class}</strong>
            <span class="profiler-text--muted">#{email.action}</span>
            {email.subject && (
              <span class="profiler-text--muted"> — {email.subject.slice(0, 60)}{email.subject.length > 60 ? '…' : ''}</span>
            )}
          </span>
        </div>
        <div class="profiler-flex profiler-flex--gap-2" style={{ flexShrink: 0 }}>
          {email.delivery_mode && <span class="badge-info profiler-text--xs">{email.delivery_mode}</span>}
          {email.duration_ms != null && (
            <span class="profiler-query-card__duration profiler-text--xs">{email.duration_ms} ms</span>
          )}
          {email.error
            ? <span class="badge-error profiler-text--xs">Error</span>
            : <span class="badge-success profiler-text--xs">Sent</span>
          }
          <span class="profiler-text--muted profiler-text--xs">{isExpanded ? '▲' : '▼'}</span>
        </div>
      </div>
      {isExpanded && <EmailDetail email={email} />}
    </div>
  )
}

// ── QUEUED ROW ────────────────────────────────────────────────────────────────

function QueuedRow({ email }: { email: MailerEmail }) {
  return (
    <div class="profiler-query-card" style={{ marginBottom: '6px', borderLeft: '3px solid var(--profiler-info, #38bdf8)' }}>
      <div class="profiler-query-card__header">
        <span class="profiler-text--sm">
          <strong>{email.mailer_class}</strong>
          <span class="profiler-text--muted">#{email.action}</span>
        </span>
        <div class="profiler-flex profiler-flex--gap-2" style={{ flexShrink: 0 }}>
          <span class="badge-info profiler-text--xs">queued</span>
          {email.delivery_method && <span class="badge-default profiler-text--xs">{email.delivery_method}</span>}
          {email.duration_ms != null && (
            <span class="profiler-query-card__duration profiler-text--xs">{email.duration_ms} ms</span>
          )}
        </div>
      </div>
      {email.assigns && Object.keys(email.assigns).length > 0 && (
        <AssignsSection assigns={email.assigns} />
      )}
    </div>
  )
}

// ── MAIN TAB ──────────────────────────────────────────────────────────────────

export function MailerTab({ mailerData }: Props) {
  const [expandedIndex, setExpandedIndex] = useState<number | null>(null)
  const [expandedErrorIndex, setExpandedErrorIndex] = useState<number | null>(null)

  const queuedCount = mailerData?.queued_count ?? 0

  if (!mailerData || (mailerData.total === 0 && queuedCount === 0)) {
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
        {mailerData.deliver_now > 0 && <span>deliver_now: <strong>{mailerData.deliver_now}</strong></span>}
        {mailerData.deliver_later > 0 && <span>deliver_later: <strong>{mailerData.deliver_later}</strong></span>}
        {queuedCount > 0 && <span>queued: <strong>{queuedCount}</strong></span>}
        {mailerData.multi_part_count > 0 && <span>Multi-part: <strong>{mailerData.multi_part_count}</strong></span>}
        {mailerData.failed > 0 && (
          <span>Errors: <strong class="profiler-text--error">{mailerData.failed}</strong></span>
        )}
      </div>

      {/* Loop warning */}
      {mailerData.loop_warnings.length > 0 && (
        <div class="profiler-alert-banner profiler-alert-banner--warning profiler-mb-4">
          <span class="profiler-alert-banner__icon">⚠️</span>
          <div style={{ flex: 1 }}>
            <strong>Send loop detected</strong> — {mailerData.loop_warnings.length} pattern{mailerData.loop_warnings.length > 1 ? 's' : ''}
            {mailerData.loop_warnings.map((w, i) => (
              <div key={i} class="profiler-text--xs profiler-text--muted profiler-mt-1">{w.message}</div>
            ))}
          </div>
        </div>
      )}

      {/* Truncation notice */}
      {mailerData.truncated && (
        <div class="profiler-alert-banner profiler-alert-banner--warning profiler-mb-4">
          <span class="profiler-alert-banner__icon">⚠️</span>
          <span>Showing first 50 emails only — additional emails were truncated</span>
        </div>
      )}

      {/* Sent emails */}
      {mailerData.emails.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-4 profiler-mb-3">
            Emails
            <span class="profiler-text--muted profiler-text--sm" style={{ fontWeight: 'normal', marginLeft: '8px' }}>
              click to expand
            </span>
          </h3>
          {mailerData.emails.map((email, i) => (
            <EmailRow key={i} email={email} onClick={() => toggleRow(i)} isExpanded={expandedIndex === i} />
          ))}
        </>
      )}

      {/* Queued (deliver_later enqueued in this request) */}
      {mailerData.queued && mailerData.queued.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-4 profiler-mb-2">
            Queued
            <span class="profiler-text--muted profiler-text--sm" style={{ fontWeight: 'normal', marginLeft: '8px' }}>
              deliver_later — will be sent in a background job
            </span>
          </h3>
          {mailerData.queued.map((email, i) => (
            <QueuedRow key={`q-${i}`} email={email} />
          ))}
        </>
      )}

      {/* Delivery errors */}
      {mailerData.errors.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-6 profiler-mb-3 profiler-text--error">
            Delivery Errors
          </h3>
          {mailerData.errors.map((email, i) => (
            <EmailRow key={`err-${i}`} email={email} onClick={() => toggleErrorRow(i)} isExpanded={expandedErrorIndex === i} />
          ))}
        </>
      )}
    </>
  )
}
