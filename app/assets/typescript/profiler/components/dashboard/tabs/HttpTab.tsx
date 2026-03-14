import { useState } from 'preact/hooks'
import { HttpData, HttpRequest } from '../../../dashboard/types'

interface Props {
  httpData: HttpData | undefined
}

function methodBadge(method: string): string {
  const map: Record<string, string> = { GET: 'info', POST: 'success', PUT: 'warning', PATCH: 'warning', DELETE: 'error' }
  return map[method] || 'default'
}

function statusBadge(status: number): string {
  if (status === 0) return 'error'
  if (status >= 200 && status < 300) return 'success'
  if (status >= 400) return 'error'
  return 'warning'
}

function formatBytes(n: number): string {
  if (n === 0) return '0 B'
  if (n < 1024) return `${n} B`
  return `${(n / 1024).toFixed(1)} KB`
}

function HeadersTable({ headers }: { headers: Record<string, string> }) {
  const entries = Object.entries(headers)
  if (!entries.length) return <span class="profiler-text--muted profiler-text--xs">none</span>
  return (
    <table class="profiler-table profiler-table--compact">
      <tbody>
        {entries.map(([k, v]) => (
          <tr key={k}>
            <td class="profiler-text--xs profiler-text--muted" style="white-space:nowrap;padding-right:16px">{k}</td>
            <td class="profiler-text--xs" style="word-break:break-all">{v}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function BodyPreview({ body, label }: { body: string | undefined, label: string }) {
  const [expanded, setExpanded] = useState(false)
  if (!body) return <span class="profiler-text--muted profiler-text--xs">empty</span>

  const preview = expanded ? body : body.slice(0, 300)
  const truncated = body.length > 300 && !expanded

  return (
    <div>
      <pre class="profiler-code profiler-text--xs" style="white-space:pre-wrap;word-break:break-all;margin:0">{preview}{truncated ? '…' : ''}</pre>
      {body.length > 300 && (
        <button
          class="profiler-link profiler-text--xs"
          onClick={() => setExpanded(e => !e)}
          style="margin-top:4px;background:none;border:none;cursor:pointer;color:var(--profiler-accent);padding:0"
        >
          {expanded ? 'Show less' : `Show all (${body.length} chars)`}
        </button>
      )}
    </div>
  )
}

function HttpRequestDetail({ req, index, threshold }: { req: HttpRequest, index: number, threshold: number }) {
  const [open, setOpen] = useState(false)
  const isError = req.status >= 400 || req.status === 0
  const isSlow = req.duration >= threshold
  const cardCls = isError ? 'profiler-ajax-card--error' : isSlow ? 'profiler-ajax-card--warning' : 'profiler-ajax-card--success'

  return (
    <div class={`profiler-ajax-card ${cardCls}`} style="margin-bottom:8px">
      {/* Summary row — click to expand */}
      <div
        class="profiler-ajax-card__row"
        style="cursor:pointer;user-select:none"
        onClick={() => setOpen(o => !o)}
      >
        <div class="profiler-flex profiler-flex--gap-3">
          <span style="font-size:11px;color:var(--profiler-muted)">{open ? '▾' : '▸'}</span>
          <span class={`profiler-ajax-card__method badge badge-${methodBadge(req.method)}`}>{req.method}</span>
          <strong class="profiler-ajax-card__path" style="word-break:break-all">{req.url}</strong>
        </div>
        <div class="profiler-flex profiler-flex--gap-2" style="flex-shrink:0">
          <span class={`badge badge-${statusBadge(req.status)}`}>{req.status === 0 ? 'ERR' : req.status}</span>
          <span class={`badge badge-${isSlow ? 'error' : 'info'}`}>{req.duration.toFixed(2)} ms</span>
        </div>
      </div>

      {/* Sizes + backtrace always visible */}
      <div class="profiler-ajax-card__row">
        <span class="profiler-text--xs profiler-text--muted">
          ↑ {formatBytes(req.request_size)} · ↓ {formatBytes(req.response_size)}
        </span>
        {req.backtrace && req.backtrace.length > 0 && (
          <span class="profiler-text--xs profiler-text--muted" style="margin-left:12px">{req.backtrace[0]}</span>
        )}
      </div>

      {req.error && (
        <div class="profiler-ajax-card__row">
          <span class="profiler-text--xs profiler-text--error">{req.error}</span>
        </div>
      )}

      {/* Expanded detail */}
      {open && (
        <div style="padding:12px 4px 4px;border-top:1px solid rgba(0,0,0,0.08);margin-top:8px">

          {/* Request */}
          <div style="margin-bottom:16px">
            <div class="profiler-text--sm" style="font-weight:600;margin-bottom:8px;color:var(--profiler-muted)">REQUEST</div>

            <div class="profiler-text--xs profiler-text--muted" style="margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Headers</div>
            <HeadersTable headers={req.request_headers || {}} />

            {req.request_body && (
              <>
                <div class="profiler-text--xs profiler-text--muted" style="margin-top:10px;margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Body</div>
                <BodyPreview body={req.request_body} label="request" />
              </>
            )}
          </div>

          {/* Response */}
          <div>
            <div class="profiler-text--sm" style="font-weight:600;margin-bottom:8px;color:var(--profiler-muted)">RESPONSE</div>

            <div class="profiler-text--xs profiler-text--muted" style="margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Headers</div>
            <HeadersTable headers={req.response_headers || {}} />

            {req.response_body && (
              <>
                <div class="profiler-text--xs profiler-text--muted" style="margin-top:10px;margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Body</div>
                <BodyPreview body={req.response_body} label="response" />
              </>
            )}
          </div>

          {/* Full backtrace */}
          {req.backtrace && req.backtrace.length > 1 && (
            <div style="margin-top:12px">
              <div class="profiler-text--xs profiler-text--muted" style="margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Backtrace</div>
              {req.backtrace.map((frame, i) => (
                <div key={i} class="profiler-text--xs profiler-text--muted" style="padding:2px 0">{frame}</div>
              ))}
            </div>
          )}
        </div>
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
              <span class={`badge badge-${status.startsWith('2') ? 'success' : (status.startsWith('4') || status.startsWith('5') || status === 'error') ? 'error' : 'warning'}`}>
                {status}
              </span>
              <strong>{count}</strong>
            </div>
          ))}
        </div>
      </div>

      <h3 class="profiler-text--lg profiler-mb-3">Requests</h3>
      <p class="profiler-text--xs profiler-text--muted profiler-mb-3">Click a request to expand headers and body.</p>
      {httpData.requests.map((req, index) => (
        <HttpRequestDetail key={index} req={req} index={index} threshold={threshold} />
      ))}
    </>
  )
}
