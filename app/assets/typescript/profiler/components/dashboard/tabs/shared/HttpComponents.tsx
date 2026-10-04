import { useState, useEffect } from 'preact/hooks'
import { methodBadge, statusBadge } from './utils'

// ── Copy / Download buttons ───────────────────────────────────────────────────

export function CopyButton({ text }: { text: string }) {
  const [copied, setCopied] = useState(false)
  function copy() {
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }
  return (
    <button onClick={copy} class="profiler-body-download-btn profiler-text--xs" style="cursor:pointer">
      {copied ? 'Copied!' : 'Copy'}
    </button>
  )
}

function mimeToExt(mime: string): string {
  const m = mime.split(';')[0].trim().toLowerCase()
  const map: Record<string, string> = {
    'application/json': '.json',
    'application/ld+json': '.jsonld',
    'application/xml': '.xml',
    'text/xml': '.xml',
    'text/csv': '.csv',
    'application/csv': '.csv',
    'text/html': '.html',
    'text/plain': '.txt',
    'text/css': '.css',
    'application/javascript': '.js',
    'text/javascript': '.js',
    'image/svg+xml': '.svg',
    'image/png': '.png',
    'image/jpeg': '.jpg',
    'image/gif': '.gif',
    'image/webp': '.webp',
    'image/avif': '.avif',
    'application/pdf': '.pdf',
    'application/zip': '.zip',
    'application/gzip': '.gz',
    'application/octet-stream': '.bin',
  }
  return map[m] || '.bin'
}

// A blob: URL inherits the profiler's origin, which is the application's: opened in a tab,
// a blob typed text/html or image/svg+xml would run the scripts of the captured body. Blobs
// offered for download are therefore untyped; the file name keeps the extension.
function DownloadTextButton({ text, mime }: { text: string, mime: string }) {
  const [url, setUrl] = useState<string | null>(null)
  useEffect(() => {
    const objectUrl = URL.createObjectURL(new Blob([text], { type: 'application/octet-stream' }))
    setUrl(objectUrl)
    return () => URL.revokeObjectURL(objectUrl)
  }, [text, mime])

  if (!url) return null
  return (
    <a href={url} download={`body${mimeToExt(mime)}`} class="profiler-body-download-btn profiler-text--xs">
      Download
    </a>
  )
}

// ── HeadersTable ──────────────────────────────────────────────────────────────

export function HeadersTable({ headers }: { headers: Record<string, string> }) {
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

// ── SmartBodyPreview ──────────────────────────────────────────────────────────

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

function formatTextBody(body: string, category: BodyCategory): string {
  if (category === 'json') {
    try { return JSON.stringify(JSON.parse(body), null, 2) } catch { return body }
  }
  if (category === 'xml') return formatXml(body)
  return body
}

function categoryMime(category: BodyCategory): string {
  const map: Partial<Record<BodyCategory, string>> = {
    json: 'application/json',
    xml: 'application/xml',
    csv: 'text/csv',
    html: 'text/html',
    svg: 'image/svg+xml',
  }
  return map[category] || 'text/plain'
}

// The type a preview blob may carry: raster images and PDF, which run no script in the
// profiler's origin. Anything else, SVG included, stays an untyped download.
function inertPreviewType(mime: string): string {
  const m = mime.toLowerCase()
  if (m === 'application/pdf' || (m.startsWith('image/') && m !== 'image/svg+xml')) return m
  return 'application/octet-stream'
}

const PREVIEW_LIMIT = 500
const CSV_ROW_LIMIT = 10

export function SmartBodyPreview({ body, encoding, headers }: {
  body: string | undefined,
  encoding: 'text' | 'base64' | undefined,
  headers: Record<string, string>
}) {
  const [expanded, setExpanded] = useState(false)
  const [objectUrl, setObjectUrl] = useState<string | null>(null)
  const [downloadUrl, setDownloadUrl] = useState<string | null>(null)

  const category = detectContentType(headers)

  useEffect(() => {
    if (encoding !== 'base64' || !body) return
    const mime = Object.entries(headers).find(([k]) => k.toLowerCase() === 'content-type')?.[1]?.split(';')[0].trim() || 'application/octet-stream'
    const raw = atob(body)
    const bytes = new Uint8Array(raw.length)
    for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i)
    const url = URL.createObjectURL(new Blob([bytes], { type: inertPreviewType(mime) }))
    const download = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }))
    setObjectUrl(url)
    setDownloadUrl(download)
    return () => {
      URL.revokeObjectURL(url)
      URL.revokeObjectURL(download)
    }
  }, [body, encoding, headers])

  if (!body) return <span class="profiler-text--muted profiler-text--xs">empty</span>

  if (encoding === 'base64') {
    const mime = Object.entries(headers).find(([k]) => k.toLowerCase() === 'content-type')?.[1]?.split(';')[0].trim() || 'application/octet-stream'
    const filename = `body${mimeToExt(mime)}`
    return (
      <div class="profiler-body-binary">
        {objectUrl && category === 'image' && (
          <img src={objectUrl} alt="response preview" style="max-width:100%;max-height:300px;display:block;margin-bottom:8px;border-radius:4px;border:1px solid var(--profiler-border)" />
        )}
        {category === 'svg' && (
          // A data: URL rather than a blob: one: an <img> runs no script, and browsers refuse
          // to open a data: URL in a tab of its own.
          <img src={`data:image/svg+xml;base64,${body}`} alt="response preview" style="max-width:100%;max-height:300px;display:block;margin-bottom:8px;border-radius:4px;border:1px solid var(--profiler-border)" />
        )}
        {objectUrl && category === 'pdf' && (
          <iframe src={objectUrl} class="profiler-body-preview-frame" title="PDF preview" />
        )}
        <div style="display:flex;gap:8px;margin-top:4px">
          {downloadUrl && (
            <a href={downloadUrl} download={filename} class="profiler-body-download-btn profiler-text--xs">
              Download {mime}
            </a>
          )}
          <CopyButton text={body} />
        </div>
        {!objectUrl && <span class="profiler-text--muted profiler-text--xs">Loading preview…</span>}
      </div>
    )
  }

  const actualMime = Object.entries(headers).find(([k]) => k.toLowerCase() === 'content-type')?.[1]?.split(';')[0].trim() || categoryMime(category)

  if (category === 'csv') {
    const rows = parseCsv(body)
    const header = rows[0] || []
    const dataRows = rows.slice(1)
    const visible = expanded ? dataRows : dataRows.slice(0, CSV_ROW_LIMIT)
    const hasMore = dataRows.length > CSV_ROW_LIMIT
    return (
      <div>
        <div style="display:flex;gap:8px;margin-bottom:6px">
          <CopyButton text={body} />
          <DownloadTextButton text={body} mime={actualMime} />
        </div>
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

  const formatted = formatTextBody(body, category)
  const preview = expanded ? formatted : formatted.slice(0, PREVIEW_LIMIT)
  const truncated = formatted.length > PREVIEW_LIMIT && !expanded

  return (
    <div>
      <div style="display:flex;gap:8px;margin-bottom:6px">
        <CopyButton text={formatted} />
        <DownloadTextButton text={formatted} mime={actualMime} />
      </div>
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

// ── HttpReqRespDetail ─────────────────────────────────────────────────────────

export function HttpReqRespDetail({ request, response, backtrace }: {
  request: {
    headers: Record<string, string>
    body?: string
    body_encoding?: 'text' | 'base64'
    params?: Record<string, unknown>
  }
  response: {
    headers: Record<string, string>
    body?: string
    body_encoding?: 'text' | 'base64'
  }
  backtrace?: string[]
}) {
  return (
    <div style="padding:12px 4px 4px;border-top:1px solid rgba(0,0,0,0.08);margin-top:8px">

      <div style="margin-bottom:16px">
        <div class="profiler-text--sm" style="font-weight:600;margin-bottom:8px;color:var(--profiler-muted)">REQUEST</div>

        <div class="profiler-text--xs profiler-text--muted" style="margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Headers</div>
        <HeadersTable headers={request.headers} />

        {request.params && Object.keys(request.params).length > 0 && !request.body && (
          <>
            <div class="profiler-text--xs profiler-text--muted" style="margin-top:10px;margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Params</div>
            <pre class="profiler-code profiler-text--xs" style="margin:0">{JSON.stringify(request.params, null, 2)}</pre>
          </>
        )}

        {request.body && (
          <>
            <div class="profiler-text--xs profiler-text--muted" style="margin-top:10px;margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Body</div>
            <SmartBodyPreview body={request.body} encoding={request.body_encoding} headers={request.headers} />
          </>
        )}
      </div>

      <div>
        <div class="profiler-text--sm" style="font-weight:600;margin-bottom:8px;color:var(--profiler-muted)">RESPONSE</div>

        <div class="profiler-text--xs profiler-text--muted" style="margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Headers</div>
        <HeadersTable headers={response.headers} />

        {response.body && (
          <>
            <div class="profiler-text--xs profiler-text--muted" style="margin-top:10px;margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Body</div>
            <SmartBodyPreview body={response.body} encoding={response.body_encoding} headers={response.headers} />
          </>
        )}
      </div>

      {backtrace && backtrace.length > 1 && (
        <div style="margin-top:12px">
          <div class="profiler-text--xs profiler-text--muted" style="margin-bottom:4px;text-transform:uppercase;letter-spacing:.5px">Backtrace</div>
          {backtrace.map((frame, i) => (
            <div key={i} class="profiler-text--xs profiler-text--muted" style="padding:2px 0">{frame}</div>
          ))}
        </div>
      )}
    </div>
  )
}

// ── HttpCardHeader ────────────────────────────────────────────────────────────

export function HttpCardHeader({ method, url, copyUrl: copyUrlOverride, status, duration, curlCommand, expandable, open, onToggle }: {
  method: string
  url: string
  copyUrl?: string
  status: number
  duration: number
  curlCommand: string
  expandable?: boolean
  open?: boolean
  onToggle?: () => void
}) {
  const [copiedUrl, setCopiedUrl] = useState(false)
  const [copiedCurl, setCopiedCurl] = useState(false)

  function handleCopyUrl(e: MouseEvent) {
    e.stopPropagation()
    navigator.clipboard.writeText(copyUrlOverride ?? url).then(() => {
      setCopiedUrl(true)
      setTimeout(() => setCopiedUrl(false), 2000)
    })
  }

  function handleCopyCurl(e: MouseEvent) {
    e.stopPropagation()
    navigator.clipboard.writeText(curlCommand).then(() => {
      setCopiedCurl(true)
      setTimeout(() => setCopiedCurl(false), 2000)
    })
  }

  return (
    <div
      class="profiler-ajax-card__row"
      style={expandable ? 'cursor:pointer;user-select:none' : undefined}
      onClick={expandable ? onToggle : undefined}
    >
      <div class="profiler-flex profiler-flex--gap-3" style="min-width:0;flex:1">
        {expandable && <span style="font-size:11px;color:var(--profiler-muted)">{open ? '▾' : '▸'}</span>}
        <span class={`profiler-ajax-card__method badge-${methodBadge(method)}`}>{method}</span>
        <strong class="profiler-ajax-card__path" style="word-break:break-all">{url}</strong>
        <button
          onClick={handleCopyUrl}
          class="profiler-body-download-btn profiler-text--xs"
          style="flex-shrink:0;cursor:pointer"
          title="Copy URL"
        >
          {copiedUrl ? 'Copied!' : 'Copy URL'}
        </button>
        <button
          onClick={handleCopyCurl}
          class="profiler-body-download-btn profiler-text--xs"
          style="flex-shrink:0;cursor:pointer"
          title="Copy as cURL"
        >
          {copiedCurl ? 'Copied!' : 'Copy as cURL'}
        </button>
      </div>
      <div class="profiler-flex profiler-flex--gap-2" style="flex-shrink:0">
        <span class={`badge-${statusBadge(status)}`}>{status === 0 ? 'ERR' : status}</span>
        <span class={duration >= 500 ? 'badge-error' : duration >= 100 ? 'badge-warning' : 'badge-success'}>{duration.toFixed(2)} ms</span>
      </div>
    </div>
  )
}
