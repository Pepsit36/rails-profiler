import { useState } from 'preact/hooks'
import { HttpData, HttpRequest } from '../../../dashboard/types'
import { formatBytes } from './shared/utils'
import { HttpCardHeader, HttpReqRespDetail } from './shared/HttpComponents'

interface Props {
  httpData: HttpData | undefined
}

function waterfallBarColor(status: number, duration: number): string {
  if (status === 0 || status >= 500) return 'var(--profiler-error, #ef4444)'
  if (status >= 400) return 'var(--profiler-warning, #f59e0b)'
  if (duration >= 500) return 'var(--profiler-warning, #f59e0b)'
  return 'var(--profiler-success, #22c55e)'
}

function WaterfallView({ requests }: { requests: HttpRequest[] }) {
  const timed = requests
    .filter(r => r.started_at)
    .map(r => ({ ...r, startMs: new Date(r.started_at!).getTime() }))

  if (!timed.length) {
    return <div class="profiler-text--muted profiler-text--sm">No timing data available (started_at missing).</div>
  }

  const minStart = Math.min(...timed.map(r => r.startMs))
  const maxEnd = Math.max(...timed.map(r => r.startMs + r.duration))
  const totalSpan = maxEnd - minStart || 1

  const ticks = [0, 0.25, 0.5, 0.75, 1].map(f => ({
    pct: f * 100,
    label: `${Math.round(f * totalSpan)}ms`
  }))

  return (
    <div>
      <div style="display:flex;position:relative;margin-left:200px;margin-bottom:4px;height:16px">
        {ticks.map(t => (
          <div key={t.pct} style={`position:absolute;left:${t.pct}%;font-size:10px;color:var(--profiler-text-muted);transform:translateX(-50%)`}>
            {t.label}
          </div>
        ))}
      </div>
      <div style="position:relative">
        {ticks.map(t => (
          <div key={t.pct} style={`position:absolute;left:calc(200px + ${t.pct}% * (100% - 200px) / 100);top:0;bottom:0;width:1px;background:var(--profiler-border);opacity:0.5;pointer-events:none`} />
        ))}
        {timed.map((req, i) => {
          const left = ((req.startMs - minStart) / totalSpan) * 100
          const width = Math.max((req.duration / totalSpan) * 100, 0.5)
          const path = req.url.replace(/^https?:\/\/[^/]+/, '') || req.url
          const color = waterfallBarColor(req.status, req.duration)
          return (
            <div key={i} style="display:flex;align-items:center;gap:0;margin-bottom:3px;height:22px">
              <div
                title={req.url}
                style="width:200px;flex-shrink:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:11px;color:var(--profiler-text-muted);padding-right:8px;text-align:right"
              >
                <span style={`font-size:10px;font-weight:600;margin-right:4px;color:${color}`}>{req.method}</span>
                {path}
              </div>
              <div style="flex:1;position:relative;height:14px;background:var(--profiler-bg-lighter);border-radius:2px">
                <div
                  style={`position:absolute;left:${left}%;width:${width}%;min-width:2px;height:100%;background:${color};border-radius:2px;opacity:0.85`}
                  title={`${req.duration.toFixed(2)}ms · ${req.status || 'ERR'}`}
                />
              </div>
              <div style="width:52px;text-align:right;font-size:11px;color:var(--profiler-text-muted);padding-left:6px;flex-shrink:0">
                {req.duration.toFixed(0)}ms
              </div>
            </div>
          )
        })}
      </div>
      <div class="profiler-text--xs profiler-text--muted" style="margin-top:8px">
        Total span: {totalSpan.toFixed(0)}ms · {timed.length} request{timed.length !== 1 ? 's' : ''}
      </div>
    </div>
  )
}

function buildCurl(req: HttpRequest): string {
  const parts = [`curl -X ${req.method}`]
  const headers = req.request_headers || {}
  for (const [k, v] of Object.entries(headers)) {
    parts.push(`  -H ${JSON.stringify(`${k}: ${v}`)}`)
  }
  if (req.request_body && req.request_body_encoding !== 'base64') {
    parts.push(`  -d ${JSON.stringify(req.request_body)}`)
  }
  parts.push(`  ${JSON.stringify(req.url)}`)
  return parts.join(' \\\n')
}

// What the profile left out of the bodies (max_captured_body_bytes, a stream sent unread).
function bodyNotes(req: HttpRequest): string[] {
  const notes: string[] = []
  if (req.request_body_not_captured) notes.push('Request body not captured: a stream that cannot be rewound is sent unread.')
  if (req.request_body_truncated) notes.push('Request body truncated: only the beginning was kept (max_captured_body_bytes).')
  if (req.response_body_truncated) notes.push('Response body truncated: only the beginning was kept (max_captured_body_bytes).')
  return notes
}

export function HttpRequestDetail({ req, index, threshold }: { req: HttpRequest, index: number, threshold: number }) {
  const [open, setOpen] = useState(false)
  const isError = req.status >= 400 || req.status === 0
  const isSlow = req.duration >= threshold
  const cardCls = isError ? 'profiler-ajax-card--error' : isSlow ? 'profiler-ajax-card--warning' : 'profiler-ajax-card--success'

  return (
    <div class={`profiler-ajax-card ${cardCls}`} style="margin-bottom:8px">
      <HttpCardHeader
        method={req.method}
        url={req.url}
        status={req.status}
        duration={req.duration}
        curlCommand={buildCurl(req)}
        expandable
        open={open}
        onToggle={() => setOpen(o => !o)}
      />

      <div class="profiler-ajax-card__row">
        <span class="profiler-text--xs profiler-text--muted">
          ↑ {req.request_size == null ? 'size unknown' : formatBytes(req.request_size)} · ↓ {formatBytes(req.response_size)}
        </span>
        {req.backtrace && req.backtrace.length > 0 && (
          <span class="profiler-text--xs profiler-text--muted" style="margin-left:12px">{req.backtrace[0]}</span>
        )}
      </div>

      {bodyNotes(req).map(note => (
        <div class="profiler-ajax-card__row">
          <span class="profiler-text--xs profiler-text--muted">{note}</span>
        </div>
      ))}

      {req.error && (
        <div class="profiler-ajax-card__row">
          <span class="profiler-text--xs profiler-text--error">{req.error}</span>
        </div>
      )}

      {open && (
        <HttpReqRespDetail
          request={{ headers: req.request_headers || {}, body: req.request_body ?? undefined, body_encoding: req.request_body_encoding as 'text' | 'base64' | undefined }}
          response={{ headers: req.response_headers || {}, body: req.response_body ?? undefined, body_encoding: req.response_body_encoding as 'text' | 'base64' | undefined }}
          backtrace={req.backtrace}
        />
      )}
    </div>
  )
}

export function HttpTab({ httpData }: Props) {
  if (!httpData?.requests?.length) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">🔗</div>
        <h3 class="profiler-empty__title">No outbound HTTP requests</h3>
        <p class="profiler-empty__description">External API calls made during this request will appear here.</p>
      </div>
    )
  }

  const threshold = 500
  const avgDuration = httpData.total_duration / httpData.total_requests

  return (
    <>
      <h2 class="profiler-section__header">Outbound HTTP ({httpData.total_requests})</h2>
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Total: <strong>{httpData.total_duration.toFixed(2)} ms</strong></span>
        <span>Avg: <strong>{avgDuration.toFixed(2)} ms</strong></span>
        <span>Slow (&gt;{threshold}ms): <strong class={httpData.slow_requests > 0 ? 'profiler-text--error' : ''}>{httpData.slow_requests}</strong></span>
        <span>Errors: <strong class={httpData.error_requests > 0 ? 'profiler-text--error' : ''}>{httpData.error_requests}</strong></span>
      </div>

      <div class="profiler-grid profiler-grid--2 profiler-mb-6">
        <div class="profiler-panel profiler-panel--sm">
          <h3 class="profiler-text--sm profiler-text--muted profiler-text--uppercase profiler-mb-3">By Host</h3>
          {Object.entries(httpData.by_host).map(([host, count]) => (
            <div key={host} class="profiler-kv-row">
              <span class="profiler-text--sm">{host}</span>
              <strong>{count}</strong>
            </div>
          ))}
        </div>
        <div class="profiler-panel profiler-panel--sm">
          <h3 class="profiler-text--sm profiler-text--muted profiler-text--uppercase profiler-mb-3">By Status</h3>
          {Object.entries(httpData.by_status).map(([status, count]) => (
            <div key={status} class="profiler-kv-row">
              <span class={`badge-${status.startsWith('2') ? 'success' : (status.startsWith('4') || status.startsWith('5') || status === 'error') ? 'error' : 'warning'}`}>
                {status}
              </span>
              <strong>{count}</strong>
            </div>
          ))}
        </div>
      </div>

      <h3 class="profiler-text--lg profiler-mb-3">Requests</h3>
      <WaterfallView requests={httpData.requests} />
      <div style="margin-top:16px">
        <p class="profiler-text--xs profiler-text--muted profiler-mb-3">Click a request to expand headers and body.</p>
        {httpData.requests.map((req, index) => (
          <HttpRequestDetail key={index} req={req} index={index} threshold={threshold} />
        ))}
      </div>
    </>
  )
}
