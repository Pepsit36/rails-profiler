import { useState, useEffect } from 'preact/hooks'
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

type BodyCategory = 'json' | 'xml' | 'csv' | 'html' | 'text' | 'image' | 'pdf' | 'svg' | 'binary'

function detectContentType(headers: Record<string, string>): BodyCategory {
  const ct = Object.entries(headers).find(([k]) => k.toLowerCase() === 'content-type')?.[1] || ''
  const mime = ct.split(';')[0].trim().toLowerCase()
  if (mime.includes('json')) return 'json'
  if (mime === 'image/svg+xml') return 'svg'
  if (mime.startsWith('image/')) return 'image'
  if (mime === 'application/pdf') return 'pdf'
  if (mime.includes('xml')) return 'xml'
  if (mime === 'text/csv' || mime === 'application/csv') return 'csv'
  if (mime === 'text/html') return 'html'
  if (mime.startsWith('application/') && !mime.includes('json') && !mime.includes('xml') && !mime.includes('javascript')) return 'binary'
  return 'text'
}

function formatXml(raw: string): string {
  try {
    let indent = 0
    return raw
      .replace(/>\s*</g, '><')
      .replace(/(<\/?[^>]+>)/g, (tag) => {
        if (tag.startsWith('</')) {
          indent = Math.max(0, indent - 1)
          return '\n' + '  '.repeat(indent) + tag
        }
        if (tag.endsWith('/>') || /<\?/.test(tag)) {
          return '\n' + '  '.repeat(indent) + tag
        }
        const out = '\n' + '  '.repeat(indent) + tag
        indent++
        return out
      })
      .trim()
  } catch {
    return raw
  }
}

function parseCsv(raw: string): string[][] {
  return raw.split('\n').filter(Boolean).map(line => {
    const cols: string[] = []
    let cur = ''
    let inQ = false
    for (let i = 0; i < line.length; i++) {
      const ch = line[i]
      if (ch === '"') { inQ = !inQ }
      else if (ch === ',' && !inQ) { cols.push(cur); cur = '' }
      else { cur += ch }
    }
    cols.push(cur)
    return cols
  })
}

function formatTextBody(body: string, category: BodyCategory): string | null {
  if (category === 'json') {
    try { return JSON.stringify(JSON.parse(body), null, 2) } catch { return body }
  }
  if (category === 'xml') return formatXml(body)
  return body
}

const PREVIEW_LIMIT = 500
const CSV_ROW_LIMIT = 10

function SmartBodyPreview({ body, encoding, headers }: {
  body: string | undefined,
  encoding: 'text' | 'base64' | undefined,
  headers: Record<string, string>
}) {
  const [expanded, setExpanded] = useState(false)
  const [objectUrl, setObjectUrl] = useState<string | null>(null)

  const category = detectContentType(headers)

  useEffect(() => {
    if (encoding !== 'base64' || !body) return
    const mime = Object.entries(headers).find(([k]) => k.toLowerCase() === 'content-type')?.[1]?.split(';')[0].trim() || 'application/octet-stream'
    const raw = atob(body)
    const bytes = new Uint8Array(raw.length)
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
    const url = URL.createObjectURL(new Blob([bytes], { type: mime }))
    setObjectUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [body, encoding, headers])

  if (!body) return <span class="profiler-text--muted profiler-text--xs">empty</span>

  if (encoding === 'base64') {
    const mime = Object.entries(headers).find(([k]) => k.toLowerCase() === 'content-type')?.[1]?.split(';')[0].trim() || 'application/octet-stream'
    const filename = mime.replace('/', '_').replace(/[^a-z0-9_]/gi, '') + '_download'

    return (
      <div class="profiler-body-binary">
        {objectUrl && (category === 'image' || category === 'svg') && (
          <img src={objectUrl} alt="response preview" style="max-width:100%;max-height:300px;display:block;margin-bottom:8px;border-radius:4px;border:1px solid var(--profiler-border)" />
        )}
        {objectUrl && category === 'pdf' && (
          <iframe src={objectUrl} class="profiler-body-preview-frame" title="PDF preview" />
        )}
        {objectUrl && (
          <a href={objectUrl} download={filename} class="profiler-body-download-btn profiler-text--xs">
            Download {mime}
          </a>
        )}
        {!objectUrl && <span class="profiler-text--muted profiler-text--xs">Loading preview…</span>}
      </div>
    )
  }

  // Text path (encoding === 'text' or undefined for backwards compat)
  if (category === 'csv') {
    const rows = parseCsv(body)
    const header = rows[0] || []
    const dataRows = rows.slice(1)
    const visible = expanded ? dataRows : dataRows.slice(0, CSV_ROW_LIMIT)
    const hasMore = dataRows.length > CSV_ROW_LIMIT

    return (
      <div>
        <div style="overflow-x:auto">
          <table class="profiler-body-csv">
            <thead>
              <tr>{header.map((h, i) => <th key={i}>{h}</th>)}</tr>
            </thead>
            <tbody>
              {visible.map((row, i) => (
                <tr key={i}>{row.map((cell, j) => <td key={j}>{cell}</td>)}</tr>
              ))}
            </tbody>
          </table>
        </div>
        {hasMore && (
          <button
            class="profiler-link profiler-text--xs"
            onClick={() => setExpanded(e => !e)}
            style="margin-top:4px;background:none;border:none;cursor:pointer;color:var(--profiler-accent);padding:0"
          >
            {expanded ? 'Show less' : `Show all (${dataRows.length} rows)`}
          </button>
        )}
      </div>
    )
  }

  const formatted = formatTextBody(body, category) ?? body
  const preview = expanded ? formatted : formatted.slice(0, PREVIEW_LIMIT)
  const truncated = formatted.length > PREVIEW_LIMIT && !expanded

  return (
    <div>
      <pre class="profiler-code profiler-text--xs" style="white-space:pre-wrap;word-break:break-all;margin:0">{preview}{truncated ? '…' : ''}</pre>
      {formatted.length > PREVIEW_LIMIT && (
        <button
          class="profiler-link profiler-text--xs"
          onClick={() => setExpanded(e => !e)}
          style="margin-top:4px;background:none;border:none;cursor:pointer;color:var(--profiler-accent);padding:0"
        >
          {expanded ? 'Show less' : `Show all (${formatted.length} chars)`}
        </button>
      )}
    </div>
  )
}

export function HttpRequestDetail({ req, index, threshold }: { req: HttpRequest, index: number, threshold: number }) {
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
          <span class={`profiler-ajax-card__method badge-${methodBadge(req.method)}`}>{req.method}</span>
          <strong class="profiler-ajax-card__path" style="word-break:break-all">{req.url}</strong>
        </div>
        <div class="profiler-flex profiler-flex--gap-2" style="flex-shrink:0">
          <span class={`badge-${statusBadge(req.status)}`}>{req.status === 0 ? 'ERR' : req.status}</span>
          <span class={req.duration >= 500 ? 'badge-error' : req.duration >= 100 ? 'badge-warning' : 'badge-success'}>{req.duration.toFixed(2)} ms</span>
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
                <SmartBodyPreview body={req.request_body} encoding={req.request_body_encoding} headers={req.request_headers || {}} />
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
                <SmartBodyPreview body={req.response_body} encoding={req.response_body_encoding} headers={req.response_headers || {}} />
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
              <span class={`badge-${status.startsWith('2') ? 'success' : (status.startsWith('4') || status.startsWith('5') || status === 'error') ? 'error' : 'warning'}`}>
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
