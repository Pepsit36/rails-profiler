import { useState, useEffect } from 'preact/hooks'
import { useExplainQuery } from '../../../generated/api'
import { DatabaseData, DatabaseQuery } from '../../../dashboard/types'

interface Props {
  dbData: DatabaseData | undefined
  token: string
}

function normalizeSql(sql: string): string {
  return sql
    .replace(/\$\d+/g, '?')
    .replace(/\b\d+\b/g, '?')
    .replace(/'[^']*'/g, '?')
    .replace(/"[^"]*"/g, '?')
    .trim()
}

interface N1Group {
  pattern: string
  indices: number[]
  backtrace: string[]
}

function computeN1Groups(queries: DatabaseQuery[]): N1Group[] {
  const groups = new Map<string, { indices: number[]; backtrace: string[] }>()

  queries.forEach((query, index) => {
    if (query.cached || query.transaction) return
    const pattern = normalizeSql(query.sql)
    if (!groups.has(pattern)) {
      groups.set(pattern, { indices: [], backtrace: query.backtrace ?? [] })
    }
    groups.get(pattern)!.indices.push(index)
  })

  const result: N1Group[] = []
  groups.forEach(({ indices, backtrace }, pattern) => {
    if (indices.length >= 3) {
      result.push({ pattern, indices, backtrace })
    }
  })
  return result.sort((a, b) => b.indices.length - a.indices.length)
}

// ── EXPLAIN ANALYZE ──────────────────────────────────────────────────────────

interface ExplainState {
  open: boolean
  loading: boolean
  result: any
  format: 'json' | 'text'
  adapter: string
  error: string | null
}

function renderPlanNode(node: any, depth: number = 0): any {
  const type: string = node['Node Type'] ?? ''
  const actualRows: number = node['Actual Rows'] ?? 0
  const planRows: number = node['Plan Rows'] ?? 1
  const isExpensive =
    type.includes('Seq Scan') ||
    type.includes('Hash Join') ||
    type.includes('Nested Loop') ||
    type.includes('Filter') ||
    (actualRows > 0 && planRows > 0 && actualRows > planRows * 10)

  const children: any[] = node['Plans'] ?? []

  return (
    <div class={`profiler-explain-node${isExpensive ? ' profiler-explain-node--expensive' : ''}`} style={`margin-left:${depth * 14}px`}>
      <span class="profiler-explain-node__type">{type}</span>
      {node['Relation Name'] && <span class="profiler-text--muted"> on {node['Relation Name']}</span>}
      {node['Index Name'] && <span class="profiler-text--muted"> using {node['Index Name']}</span>}
      <div class="profiler-explain-node__stats profiler-text--xs profiler-text--muted">
        {node['Actual Total Time'] != null && <span>time: {(node['Actual Total Time'] as number).toFixed(3)}ms</span>}
        {node['Actual Rows'] != null && <span>rows: {actualRows} (est: {planRows})</span>}
        {node['Total Cost'] != null && <span>cost: {(node['Total Cost'] as number).toFixed(2)}</span>}
        {node['Filter'] && <span class="profiler-text--warning">filter: {node['Filter']}</span>}
      </div>
      {children.map((child: any, i: number) => renderPlanNode(child, depth + 1))}
    </div>
  )
}

function ExplainModal({ state, onClose }: { state: ExplainState; onClose: () => void }) {
  useEffect(() => {
    if (!state.open) return
    const handler = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose() }
    document.addEventListener('keydown', handler)
    return () => document.removeEventListener('keydown', handler)
  }, [state.open])

  if (!state.open) return null

  const renderResult = () => {
    if (state.loading) return <div class="profiler-text--muted">Running EXPLAIN ANALYZE…</div>
    if (state.error) return <div class="profiler-text--error">{state.error}</div>
    if (!state.result) return null

    if (state.format === 'json') {
      try {
        const parsed = typeof state.result === 'string' ? JSON.parse(state.result) : state.result
        const plans: any[] = Array.isArray(parsed) ? parsed : [parsed]
        return (
          <div class="profiler-explain-result">
            {plans.map((entry: any, i: number) => (
              <div key={i}>
                {renderPlanNode(entry['Plan'] ?? entry)}
                {entry['Planning Time'] != null && (
                  <div class="profiler-text--xs profiler-text--muted profiler-mt-2">
                    Planning: {(entry['Planning Time'] as number).toFixed(3)}ms
                    {entry['Execution Time'] != null && <> · Execution: {(entry['Execution Time'] as number).toFixed(3)}ms</>}
                  </div>
                )}
              </div>
            ))}
          </div>
        )
      } catch {
        return <pre class="profiler-explain-result">{String(state.result)}</pre>
      }
    }

    return <pre class="profiler-explain-result">{String(state.result)}</pre>
  }

  return (
    <div class="profiler-modal__overlay" onClick={onClose}>
      <div class="profiler-modal" onClick={(e: MouseEvent) => e.stopPropagation()}>
        <div class="profiler-modal__header">
          <span class="profiler-modal__title">EXPLAIN ANALYZE</span>
          <span class="profiler-text--xs profiler-text--muted">{state.adapter}</span>
          <button class="profiler-modal__close" onClick={onClose}>×</button>
        </div>
        <div class="profiler-modal__body">
          {renderResult()}
        </div>
      </div>
    </div>
  )
}

// ── MAIN COMPONENT ────────────────────────────────────────────────────────────

export function DatabaseTab({ dbData, token }: Props) {
  const [openBacktraces, setOpenBacktraces] = useState<Set<string>>(new Set())
  const [explainState, setExplainState] = useState<ExplainState>({
    open: false, loading: false, result: null, format: 'text', adapter: '', error: null
  })
  const { mutateAsync: runExplainMutation } = useExplainQuery()

  if (!dbData?.queries) {
    return (
      <div class="profiler-empty">
        <p class="profiler-empty__description">No database queries recorded</p>
      </div>
    )
  }

  const n1Groups = computeN1Groups(dbData.queries)
  const n1IndexSet = new Set(n1Groups.flatMap(g => g.indices))

  const toggleBacktrace = (pattern: string) => {
    setOpenBacktraces(prev => {
      const next = new Set(prev)
      next.has(pattern) ? next.delete(pattern) : next.add(pattern)
      return next
    })
  }

  const runExplain = async (queryIndex: number) => {
    setExplainState({ open: true, loading: true, result: null, format: 'text', adapter: '', error: null })
    try {
      const data = await runExplainMutation({ token, query_index: queryIndex })
      setExplainState(s => ({
        ...s,
        loading: false,
        result: data.result,
        format: data.format ?? 'text',
        adapter: data.adapter ?? ''
      }))
    } catch (err: any) {
      setExplainState(s => ({ ...s, loading: false, error: err.message ?? 'Request failed' }))
    }
  }

  const closeExplain = () => setExplainState(s => ({ ...s, open: false }))

  return (
    <>
      <h2 class="profiler-section__header">Database Queries ({dbData.total_queries})</h2>
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Total Duration: <strong>{dbData.total_duration} ms</strong></span>
        <span>Slow Queries: <strong class="profiler-text--error">{dbData.slow_queries}</strong></span>
        <span>Cached: <strong>{dbData.cached_queries}</strong></span>
      </div>

      {n1Groups.length > 0 && (
        <div class="profiler-alert-banner profiler-alert-banner--warning profiler-mb-4">
          <span class="profiler-alert-banner__icon">⚠️</span>
          <div style="flex:1">
            <strong>Potential N+1 detected</strong> — {n1Groups.length} pattern{n1Groups.length > 1 ? 's' : ''} repeated {n1Groups.reduce((sum, g) => sum + g.indices.length, 0)} times total
            <div class="profiler-text--xs profiler-text--muted profiler-mt-1">
              Queries causing N+1 are highlighted below. Expand each group to see the call stack.
            </div>
          </div>
          {n1Groups.length > 1 && (
            <button
              class="profiler-btn profiler-btn--sm"
              style="flex-shrink:0;align-self:flex-start"
              onClick={() => {
                const allOpen = n1Groups.every(g => openBacktraces.has(g.pattern))
                setOpenBacktraces(allOpen ? new Set() : new Set(n1Groups.map(g => g.pattern)))
              }}
            >
              {n1Groups.every(g => openBacktraces.has(g.pattern)) ? 'Collapse all' : 'Expand all'}
            </button>
          )}
        </div>
      )}

      {n1Groups.map((group) => (
        <div key={group.pattern} class="profiler-n1-group profiler-mb-4">
          <div class="profiler-n1-group__header" onClick={() => toggleBacktrace(group.pattern)}>
            <span class="profiler-n1-group__count">N+1 · {group.indices.length}×</span>
            <code class="profiler-n1-group__pattern">{group.pattern}</code>
            <span class="profiler-n1-group__toggle">{openBacktraces.has(group.pattern) ? '▲' : '▼'} backtrace</span>
          </div>
          {openBacktraces.has(group.pattern) && group.backtrace.length > 0 && (
            <div class="profiler-n1-backtrace">
              {group.backtrace.map((frame, i) => (
                <div key={i} class="profiler-n1-backtrace__frame">{frame}</div>
              ))}
            </div>
          )}
        </div>
      ))}

      {dbData.queries.map((query, index) => (
        <div key={index} class={[
          'profiler-query-card',
          query.slow ? 'profiler-query-card--slow' : '',
          n1IndexSet.has(index) ? 'profiler-query-card--n1' : ''
        ].filter(Boolean).join(' ')}>
          <div class="profiler-query-card__header">
            <div class="profiler-flex profiler-flex--gap-2">
              <span class="profiler-text--muted">#{index + 1}</span>
              {n1IndexSet.has(index) && <span class="profiler-badge profiler-badge--warning">N+1</span>}
              {query.name && <span class="profiler-text--xs profiler-text--muted">{query.name}</span>}
            </div>
            <div class="profiler-flex profiler-flex--gap-2">
              <span class={`profiler-query-card__duration ${query.slow ? 'profiler-query-card__duration--slow' : 'profiler-query-card__duration--fast'}`}>
                {query.duration.toFixed(2)} ms
              </span>
              {!query.cached && !query.transaction && (
                <button class="profiler-btn profiler-btn--sm" onClick={() => runExplain(index)}>
                  Explain
                </button>
              )}
            </div>
          </div>
          <code class="profiler-query-card__code">{query.sql}</code>
        </div>
      ))}

      <ExplainModal state={explainState} onClose={closeExplain} />
    </>
  )
}
