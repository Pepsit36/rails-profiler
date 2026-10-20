import { useState, useEffect } from 'preact/hooks'

const BASE = '/_profiler'

interface SqlEntry {
  fingerprint: string
  count_a: number
  count_b: number
  total_duration_a: number
  total_duration_b: number
  delta_pct?: number
}

interface ProfileSummary {
  token: string
  node?: string
  allocated_objects?: number
  path: string
  method: string
  status: number
  duration: number
  memory?: number
  started_at: string
  profile_type: string
}

interface MetricDiff {
  value_a: number | null
  value_b: number | null
  delta: number
  delta_pct: number | null
  status: 'improved' | 'regression' | 'neutral'
}

interface DatabaseCollector {
  total_queries_a: number | null
  total_queries_b: number | null
  total_duration_a: number | null
  total_duration_b: number | null
  slow_queries_a: number | null
  slow_queries_b: number | null
  cached_queries_a: number | null
  cached_queries_b: number | null
  queries_a: any[]
  queries_b: any[]
}

interface CacheCollector {
  total_reads_a: number | null
  total_reads_b: number | null
  total_writes_a: number | null
  total_writes_b: number | null
  hit_rate_a: number | null
  hit_rate_b: number | null
}

interface ViewsCollector {
  total_views_a: number | null
  total_views_b: number | null
  total_partials_a: number | null
  total_partials_b: number | null
  total_duration_a: number | null
  total_duration_b: number | null
}

interface HttpCollector {
  total_requests_a: number | null
  total_requests_b: number | null
  total_duration_a: number | null
  total_duration_b: number | null
  slow_requests_a: number | null
  slow_requests_b: number | null
  error_requests_a: number | null
  error_requests_b: number | null
}

interface CompareData {
  profile_a: ProfileSummary
  profile_b: ProfileSummary
  same_endpoint: boolean
  sql: { new: SqlEntry[], gone: SqlEntry[], slower: SqlEntry[] }
  metrics: {
    duration?: MetricDiff
    memory?: MetricDiff
    allocated_objects?: MetricDiff
    db_queries?: MetricDiff
    db_duration?: MetricDiff
    cache_hit_rate?: MetricDiff
    view_duration?: MetricDiff
    http_requests?: MetricDiff
    http_duration?: MetricDiff
  }
  collectors: {
    database: DatabaseCollector
    cache: CacheCollector
    views: ViewsCollector
    http: HttpCollector
  }
}

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('en', { hour12: false })
}

function formatMemory(bytes?: number | null): string {
  if (bytes == null) return '-'
  return (bytes / 1024 / 1024).toFixed(2) + ' MB'
}

function formatMs(ms?: number | null): string {
  if (ms == null) return '-'
  return ms.toFixed(2) + ' ms'
}

function formatVal(val: number | null | undefined, unit = ''): string {
  if (val == null) return '-'
  return val.toFixed(2) + unit
}

// ── Markdown export helpers ──────────────────────────────────────────────────

function mdSign(v: number): string {
  return v > 0 ? `+${v.toFixed(2)}` : v.toFixed(2)
}

function mdSignPct(v: number | null): string {
  return v != null ? ` (${v > 0 ? '+' : ''}${v.toFixed(1)}%)` : ''
}

function mdMetricRow(
  label: string,
  metric?: MetricDiff,
  fmtA?: (v: number | null) => string,
  fmtB?: (v: number | null) => string
): string {
  if (!metric) return ''
  const a = fmtA ? fmtA(metric.value_a) : formatVal(metric.value_a)
  const b = fmtB ? fmtB(metric.value_b) : formatVal(metric.value_b)
  const delta = `${mdSign(metric.delta)}${mdSignPct(metric.delta_pct)}`
  const icon = metric.status === 'improved' ? '✅' : metric.status === 'regression' ? '❌' : '➖'
  return `| ${label} | ${a} | ${b} | ${delta} | ${icon} |`
}

function generateMarkdown(data: CompareData): string {
  const { profile_a: pa, profile_b: pb, metrics: m } = data
  const lines: string[] = [
    '## Profile Comparison',
    '',
    `**A:** \`${pa.token}\` - ${pa.method} ${pa.path} - ${formatTime(pa.started_at)}`,
    `**B:** \`${pb.token}\` - ${pb.method} ${pb.path} - ${formatTime(pb.started_at)}`,
  ]
  if (!data.same_endpoint) lines.push('', '> ⚠️ Profiles are from different endpoints.')
  lines.push(
    '',
    '| Metric | Before (A) | After (B) | Delta | |',
    '|--------|-----------|-----------|-------|---|',
    mdMetricRow('Duration', m.duration, formatMs, formatMs),
    mdMetricRow('Allocated objects', m.allocated_objects, formatVal, formatVal),
    mdMetricRow('DB Queries', m.db_queries, formatVal, formatVal),
    mdMetricRow('DB Duration', m.db_duration, formatMs, formatMs),
    mdMetricRow('Cache Hit Rate', m.cache_hit_rate, v => formatVal(v, '%'), v => formatVal(v, '%')),
    mdMetricRow('View Duration', m.view_duration, formatMs, formatMs),
    mdMetricRow('HTTP Requests', m.http_requests, formatVal, formatVal),
    mdMetricRow('HTTP Duration', m.http_duration, formatMs, formatMs),
  )
  return lines.filter(l => l !== '').join('\n')
}

// ── UI components ─────────────────────────────────────────────────────────────

function badgeClass(status: 'improved' | 'regression' | 'neutral'): string {
  if (status === 'improved') return 'badge-success'
  if (status === 'regression') return 'badge-error'
  return 'badge-default'
}

function DeltaBadge({ metric }: { metric?: MetricDiff }) {
  if (!metric) return <span class="badge-default">-</span>
  const sign = metric.delta > 0 ? '+' : ''
  const pct = metric.delta_pct != null ? ` (${metric.delta > 0 ? '+' : ''}${metric.delta_pct}%)` : ''
  const label = `${sign}${metric.delta.toFixed(2)}${pct}`
  return <span class={badgeClass(metric.status)}>{label}</span>
}

function ScorecardRow({ label, metric, formatA, formatB }: {
  label: string
  metric?: MetricDiff
  formatA: (v: number | null) => string
  formatB: (v: number | null) => string
}) {
  if (!metric) return null
  return (
    <tr>
      <td>{label}</td>
      <td class="profiler-text--mono">{formatA(metric.value_a)}</td>
      <td class="profiler-text--mono">{formatB(metric.value_b)}</td>
      <td><DeltaBadge metric={metric} /></td>
    </tr>
  )
}

function CollectorTable({ label, rows }: { label: string, rows: Array<{ key: string, a: string, b: string }> }) {
  const hasData = rows.some(r => r.a !== '-' || r.b !== '-')
  if (!hasData) return (
    <div class="profiler-empty profiler-mb-4">
      <div class="profiler-empty__title">No {label.toLowerCase()} data</div>
    </div>
  )

  return (
    <div class="profiler-mb-4">
      <table>
        <thead>
          <tr>
            <th>Metric</th>
            <th>Profile A</th>
            <th>Profile B</th>
          </tr>
        </thead>
        <tbody>
          {rows.map(r => (
            <tr key={r.key}>
              <td>{r.key}</td>
              <td class="profiler-text--mono">{r.a}</td>
              <td class="profiler-text--mono">{r.b}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function SqlBlock({ title, rows }: { title: string, rows: SqlEntry[] }) {
  return (
    <div class="profiler-mb-4">
      <h3>{title} ({rows.length})</h3>
      {rows.length === 0 ? <p class="profiler-text--muted">None.</p> : (
        <table>
          <thead><tr><th>Query</th><th>Count A</th><th>Count B</th><th>Time A</th><th>Time B</th></tr></thead>
          <tbody>
            {rows.map(q => (
              <tr>
                <td class="profiler-text--mono profiler-text--xs">{q.fingerprint}</td>
                <td>{q.count_a}</td>
                <td>{q.count_b}</td>
                <td>{formatMs(q.total_duration_a)}</td>
                <td>{formatMs(q.total_duration_b)}{q.delta_pct != null ? ` (+${q.delta_pct}%)` : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}

// One node selector per profile. Only the names offered by the server (config.peers) can be
// chosen; the page never builds or sends a URL.
function NodeSelect({ label, name, value, nodes, onChange }: { label: string, name: string, value: string, nodes: string[], onChange: (v: string) => void }) {
  return (
    <label style="margin-right: 16px">
      {label}{' '}
      <select name={name} value={value} onChange={e => onChange((e.target as HTMLSelectElement).value)}>
        {nodes.map(n => <option value={n}>{n}</option>)}
      </select>
    </label>
  )
}

export function CompareView({ tokenA, tokenB, nodeA = '', nodeB = '' }: { tokenA: string, tokenB: string, nodeA?: string, nodeB?: string }) {
  const [nodes, setNodes] = useState<string[]>(['local'])
  const [selA, setSelA] = useState(nodeA || 'local')
  const [selB, setSelB] = useState(nodeB || 'local')
  useEffect(() => {
    fetch(`${BASE}/api/compare/nodes`, { headers: { 'X-Profiler-Request': '1' } })
      .then(res => res.ok ? res.json() : { nodes: ['local'] })
      .then(d => setNodes(d.nodes))
      .catch(() => {})
  }, [])
  const [data, setData] = useState<CompareData | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [activeTab, setActiveTab] = useState<'sql' | 'database' | 'cache' | 'views' | 'http'>('sql')

  useEffect(() => {
    fetch(`${BASE}/api/compare?${new URLSearchParams({ a: tokenA, b: tokenB, node_a: nodeA, node_b: nodeB }).toString()}`,
      { headers: { 'X-Profiler-Request': '1' } })
      .then(res => {
        if (!res.ok) return res.json().then(d => Promise.reject(d.errors?.join(', ') || 'Error'))
        return res.json()
      })
      .then((d: CompareData) => { setData(d); setLoading(false) })
      .catch(err => { setError(typeof err === 'string' ? err : 'Failed to load comparison'); setLoading(false) })
  }, [tokenA, tokenB, nodeA, nodeB])

  // The export is a plain download link on an object URL of the generated Markdown.
  const [objectUrl, setObjectUrl] = useState('')
  useEffect(() => {
    if (!data) return
    const markdown = generateMarkdown(data)
    const blob = new Blob([markdown], { type: 'text/plain' })
    const url = URL.createObjectURL(blob)
    setObjectUrl(url)
    return () => URL.revokeObjectURL(url)
  }, [data])

  if (loading) {
    return (
      <div class="container">
        <div class="header"><h1>Profile Comparison</h1></div>
        <div class="profiler-panel profiler-p-4">
          <div class="profiler-empty"><div class="profiler-empty__title">Loading…</div></div>
        </div>
      </div>
    )
  }

  if (error || !data) {
    return (
      <div class="container">
        <div class="header"><h1>Profile Comparison</h1></div>
        <div class="profiler-panel profiler-p-4">
          <div class="profiler-empty">
            <div class="profiler-empty__title">{error || 'Unknown error'}</div>
          </div>
        </div>
      </div>
    )
  }

  const { profile_a: pa, profile_b: pb, metrics: m, collectors: c } = data

  const tabClass = (t: string) => `tab${activeTab === t ? ' active' : ''}`

  return (
    <div class="container">
      <div class="header">
        <h1>Profile Comparison</h1>
        <p>
          <a href={`${BASE}/`}>← Back to list</a>
        </p>
        {nodes.length > 1 && (
          <form method="get" action={`${BASE}/compare`}>
            <input type="hidden" name="a" value={tokenA} />
            <input type="hidden" name="b" value={tokenB} />
            <NodeSelect label="Node A" name="node_a" value={selA} nodes={nodes} onChange={setSelA} />
            <NodeSelect label="Node B" name="node_b" value={selB} nodes={nodes} onChange={setSelB} />
            <button type="submit" class="btn btn-secondary btn-sm">Compare</button>
          </form>
        )}
      </div>

      {!data.same_endpoint && (
        <div class="profiler-panel profiler-p-4 profiler-mb-4" style="border-left: 3px solid var(--color-warning, #f59e0b)">
          ⚠️ These profiles are from different endpoints - comparison may not be meaningful.
        </div>
      )}

      <div class="profiler-panel profiler-mb-4">
        <div class="profiler-p-4">
          <table>
            <thead>
              <tr>
                <th></th>
                <th>Profile A</th>
                <th>Profile B</th>
              </tr>
            </thead>
            <tbody>
              <tr>
                <td>Endpoint</td>
                <td>{pa.node === 'local' ? <a href={`${BASE}/profiles/${pa.token}`}>{pa.method} {pa.path}</a> : <span>{pa.method} {pa.path}</span>}</td>
                <td>{pb.node === 'local' ? <a href={`${BASE}/profiles/${pb.token}`}>{pb.method} {pb.path}</a> : <span>{pb.method} {pb.path}</span>}</td>
              </tr>
              <tr>
                <td>Time</td>
                <td class="profiler-text--mono">{formatTime(pa.started_at)}</td>
                <td class="profiler-text--mono">{formatTime(pb.started_at)}</td>
              </tr>
              <tr>
                <td>Token</td>
                <td class="profiler-text--xs profiler-text--mono profiler-text--muted">{pa.token.substring(0, 16)}…</td>
                <td class="profiler-text--xs profiler-text--mono profiler-text--muted">{pb.token.substring(0, 16)}…</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>

      <div class="profiler-panel profiler-mb-4">
        <div class="profiler-p-4">
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 12px">
            <h2 style="margin: 0">Scorecard</h2>
            {objectUrl && (
              <a class="btn btn-secondary btn-sm" href={objectUrl} download={`compare-${tokenA.substring(0, 8)}-vs-${tokenB.substring(0, 8)}.md`}>Export as Markdown</a>
            )}
          </div>
          <table>
            <thead>
              <tr>
                <th>Metric</th>
                <th>A</th>
                <th>B</th>
                <th>Delta</th>
              </tr>
            </thead>
            <tbody>
              <ScorecardRow label="Duration" metric={m.duration} formatA={formatMs} formatB={formatMs} />
              <ScorecardRow label="Allocated objects" metric={m.allocated_objects} formatA={v => formatVal(v)} formatB={v => formatVal(v)} />
              <ScorecardRow label="DB Queries" metric={m.db_queries} formatA={v => formatVal(v)} formatB={v => formatVal(v)} />
              <ScorecardRow label="DB Duration" metric={m.db_duration} formatA={formatMs} formatB={formatMs} />
              <ScorecardRow label="Cache Hit Rate" metric={m.cache_hit_rate} formatA={v => formatVal(v, '%')} formatB={v => formatVal(v, '%')} />
              <ScorecardRow label="View Duration" metric={m.view_duration} formatA={formatMs} formatB={formatMs} />
              <ScorecardRow label="HTTP Requests" metric={m.http_requests} formatA={v => formatVal(v)} formatB={v => formatVal(v)} />
              <ScorecardRow label="HTTP Duration" metric={m.http_duration} formatA={formatMs} formatB={formatMs} />
            </tbody>
          </table>
        </div>
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          <a href="#" class={tabClass('sql')} onClick={e => { e.preventDefault(); setActiveTab('sql') }}>SQL</a>
          <a href="#" class={tabClass('database')} onClick={e => { e.preventDefault(); setActiveTab('database') }}>Database</a>
          <a href="#" class={tabClass('cache')} onClick={e => { e.preventDefault(); setActiveTab('cache') }}>Cache</a>
          <a href="#" class={tabClass('views')} onClick={e => { e.preventDefault(); setActiveTab('views') }}>Views</a>
          <a href="#" class={tabClass('http')} onClick={e => { e.preventDefault(); setActiveTab('http') }}>HTTP</a>
        </div>

        <div class="profiler-p-4 tab-content active">
          {activeTab === 'sql' && (
            <div>
              <SqlBlock title="New queries (only in B)" rows={data.sql.new} />
              <SqlBlock title="Gone queries (only in A)" rows={data.sql.gone} />
              <SqlBlock title="Slower queries" rows={data.sql.slower} />
            </div>
          )}
          {activeTab === 'database' && (
            <CollectorTable label="Database" rows={[
              { key: 'Total Queries', a: formatVal(c.database.total_queries_a), b: formatVal(c.database.total_queries_b) },
              { key: 'Total Duration', a: formatMs(c.database.total_duration_a), b: formatMs(c.database.total_duration_b) },
              { key: 'Slow Queries', a: formatVal(c.database.slow_queries_a), b: formatVal(c.database.slow_queries_b) },
              { key: 'Cached Queries', a: formatVal(c.database.cached_queries_a), b: formatVal(c.database.cached_queries_b) },
            ]} />
          )}
          {activeTab === 'cache' && (
            <CollectorTable label="Cache" rows={[
              { key: 'Total Reads', a: formatVal(c.cache.total_reads_a), b: formatVal(c.cache.total_reads_b) },
              { key: 'Total Writes', a: formatVal(c.cache.total_writes_a), b: formatVal(c.cache.total_writes_b) },
              { key: 'Hit Rate', a: formatVal(c.cache.hit_rate_a, '%'), b: formatVal(c.cache.hit_rate_b, '%') },
            ]} />
          )}
          {activeTab === 'views' && (
            <CollectorTable label="Views" rows={[
              { key: 'Templates', a: formatVal(c.views.total_views_a), b: formatVal(c.views.total_views_b) },
              { key: 'Partials', a: formatVal(c.views.total_partials_a), b: formatVal(c.views.total_partials_b) },
              { key: 'Total Duration', a: formatMs(c.views.total_duration_a), b: formatMs(c.views.total_duration_b) },
            ]} />
          )}
          {activeTab === 'http' && (
            <CollectorTable label="HTTP" rows={[
              { key: 'Total Requests', a: formatVal(c.http.total_requests_a), b: formatVal(c.http.total_requests_b) },
              { key: 'Total Duration', a: formatMs(c.http.total_duration_a), b: formatMs(c.http.total_duration_b) },
              { key: 'Slow Requests', a: formatVal(c.http.slow_requests_a), b: formatVal(c.http.slow_requests_b) },
              { key: 'Error Requests', a: formatVal(c.http.error_requests_a), b: formatVal(c.http.error_requests_b) },
            ]} />
          )}
        </div>
      </div>
    </div>
  )
}
