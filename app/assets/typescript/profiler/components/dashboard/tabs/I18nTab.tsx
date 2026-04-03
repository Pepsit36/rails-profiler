import { useState } from 'preact/hooks'
import { I18nData, I18nLookup } from '../../../dashboard/types'

interface Props {
  i18nData: I18nData | undefined
}

type Filter = 'ALL' | 'MISSING'

export function I18nTab({ i18nData }: Props) {
  const [filter, setFilter] = useState<Filter>('ALL')

  if (!i18nData?.lookups?.length) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">🌐</div>
        <h3 class="profiler-empty__title">No translation lookups captured</h3>
        <div class="profiler-empty__description">
          <p>Calls to <code>I18n.t</code> during this request will appear here.</p>
        </div>
      </div>
    )
  }

  const filtered = filter === 'MISSING' ? i18nData.lookups.filter((l: I18nLookup) => l.missing) : i18nData.lookups

  return (
    <>
      <h2 class="profiler-section__header">I18n Lookups ({i18nData.total})</h2>

      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Locale: <strong>{i18nData.locale}</strong></span>
        {i18nData.missing_count > 0 && (
          <span>Missing: <strong class="profiler-text--error">{i18nData.missing_count}</strong></span>
        )}
      </div>

      <div class="profiler-flex profiler-flex--gap-2 profiler-mb-4">
        {(['ALL', 'MISSING'] as Filter[]).map(f => (
          <button
            key={f}
            onClick={() => setFilter(f)}
            class={`btn btn-sm ${filter === f ? 'btn-primary' : 'btn-secondary'}`}
          >
            {f}
          </button>
        ))}
      </div>

      {filtered.length === 0 ? (
        <div class="profiler-text--muted profiler-text--sm">No missing translations.</div>
      ) : (
        <table class="profiler-table">
          <thead>
            <tr>
              <th>Key</th>
              <th>Locale</th>
              <th>Value</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((entry: I18nLookup, index: number) => (
              <tr key={index} style={entry.missing ? 'background:var(--profiler-error-bg,rgba(239,68,68,0.08));' : ''}>
                <td>
                  <code class={`profiler-text--xs profiler-text--mono${entry.missing ? ' profiler-text--error' : ''}`}>
                    {entry.key}
                  </code>
                </td>
                <td>
                  <span class="profiler-text--xs profiler-text--muted">{entry.locale}</span>
                </td>
                <td>
                  <span class={`profiler-text--xs${entry.missing ? ' profiler-text--error' : ''}`}>
                    {entry.value}
                  </span>
                </td>
                <td>
                  {entry.missing
                    ? <span class="profiler-text--xs profiler-text--error" style="font-weight:600;">⚠ missing</span>
                    : <span class="profiler-text--xs profiler-text--success">✓</span>
                  }
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  )
}
