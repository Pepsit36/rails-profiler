import { useState } from 'preact/hooks'
import { RoutesData } from '../../../dashboard/types'

interface Props {
  routesData: RoutesData
}

const VERB_COLORS: Record<string, string> = {
  GET:    'var(--profiler-success)',
  POST:   'var(--profiler-accent)',
  PUT:    'var(--profiler-warning)',
  PATCH:  'var(--profiler-warning)',
  DELETE: 'var(--profiler-error)',
}

function VerbBadge({ verb }: { verb: string }) {
  const color = VERB_COLORS[verb] ?? 'var(--profiler-text-muted)'
  return (
    <span style={{
      display: 'inline-block',
      minWidth: '52px',
      textAlign: 'center',
      padding: '1px 6px',
      borderRadius: '4px',
      fontSize: '10px',
      fontWeight: 700,
      fontFamily: 'monospace',
      border: `1px solid ${color}`,
      color,
    }}>
      {verb}
    </span>
  )
}

export function RoutesTab({ routesData }: Props) {
  const [filter, setFilter] = useState('')
  const [verbFilter, setVerbFilter] = useState('ALL')

  const { total, matched, routes } = routesData

  const verbs = ['ALL', ...Array.from(new Set(routes.map(r => r.verb))).sort()]

  const filtered = routes.filter(route => {
    const matchesVerb = verbFilter === 'ALL' || route.verb === verbFilter
    const q = filter.toLowerCase()
    const matchesText = !q ||
      (route.pattern ?? '').toLowerCase().includes(q) ||
      (route.name ?? '').toLowerCase().includes(q) ||
      (route.controller_action ?? '').toLowerCase().includes(q)
    return matchesVerb && matchesText
  })

  return (
    <>
      <h2 class="profiler-section__header">Routes</h2>

      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4">
        <div class="profiler-stat-card">
          <div class="profiler-stat-card__value">{total}</div>
          <div class="profiler-stat-card__label">Total routes</div>
        </div>
      </div>

      {matched && (
        <>
          <h2 class="profiler-section__header profiler-mt-4">Matched Route</h2>
          <table class="profiler-mb-4">
            <tr>
              <th class="profiler-text--sm" style="width:120px;">Verb</th>
              <td><VerbBadge verb={matched.verb} /></td>
            </tr>
            <tr>
              <th class="profiler-text--sm">Pattern</th>
              <td class="profiler-text--mono profiler-text--xs">{matched.pattern}</td>
            </tr>
            {matched.name && (
              <tr>
                <th class="profiler-text--sm">Route Name</th>
                <td class="profiler-text--mono profiler-text--xs">{matched.name}_path</td>
              </tr>
            )}
            {matched.controller_action && (
              <tr>
                <th class="profiler-text--sm">Controller#Action</th>
                <td class="profiler-text--mono profiler-text--xs">{matched.controller_action}</td>
              </tr>
            )}
          </table>
        </>
      )}

      <h2 class="profiler-section__header profiler-mt-4">All Routes</h2>

      <div class="profiler-flex profiler-flex--gap-2 profiler-mb-3" style="flex-wrap:wrap;align-items:center;">
        <input
          type="text"
          class="profiler-filter-input"
          placeholder="Filter by path, name or controller…"
          value={filter}
          onInput={(e) => setFilter((e.target as HTMLInputElement).value)}
          style="flex:1;width:auto;min-width:200px;"
        />
        <div class="profiler-flex profiler-flex--gap-1">
          {verbs.map(v => (
            <button
              key={v}
              onClick={() => setVerbFilter(v)}
              style={{
                padding: '3px 8px',
                fontSize: '11px',
                fontWeight: 600,
                borderRadius: '4px',
                border: '1px solid var(--profiler-border)',
                background: verbFilter === v ? 'var(--profiler-accent)' : 'transparent',
                color: verbFilter === v ? '#fff' : 'var(--profiler-text-muted)',
                cursor: 'pointer',
              }}
            >
              {v}
            </button>
          ))}
        </div>
      </div>

      <div class="profiler-flex-table">
        <div class="profiler-flex-table__header">
          <span class="profiler-flex-table__cell--fixed">Verb</span>
          <span class="profiler-flex-table__cell">Pattern</span>
          <span class="profiler-flex-table__cell">Name</span>
          <span class="profiler-flex-table__cell">Controller#Action</span>
        </div>
        {filtered.map((route, i) => (
          <div key={i} class={`profiler-flex-table__row${route.matched ? ' profiler-flex-table__row--matched' : ''}`}>
            <span class="profiler-flex-table__cell--fixed"><VerbBadge verb={route.verb} /></span>
            <span class="profiler-flex-table__cell profiler-text--mono profiler-text--xs" title={route.pattern}>
              {route.pattern}
            </span>
            <span class="profiler-flex-table__cell profiler-flex-table__cell--muted profiler-text--mono profiler-text--xs" title={route.name ? `${route.name}_path` : ''}>
              {route.name ? `${route.name}_path` : '—'}
            </span>
            <span class="profiler-flex-table__cell profiler-flex-table__cell--muted profiler-text--mono profiler-text--xs" title={route.controller_action ?? ''}>
              {route.controller_action ?? '—'}
            </span>
          </div>
        ))}
      </div>
    </>
  )
}
