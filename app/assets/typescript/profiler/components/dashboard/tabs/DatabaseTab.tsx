import { DatabaseData } from '../../../dashboard/types'

interface Props {
  dbData: DatabaseData | undefined
}

export function DatabaseTab({ dbData }: Props) {
  if (!dbData?.queries) {
    return (
      <div class="profiler-empty">
        <p class="profiler-empty__description">No database queries recorded</p>
      </div>
    )
  }

  return (
    <>
      <h2 class="profiler-section__header">Database Queries ({dbData.total_queries})</h2>
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Total Duration: <strong>{dbData.total_duration} ms</strong></span>
        <span>Slow Queries: <strong class="profiler-text--error">{dbData.slow_queries}</strong></span>
        <span>Cached: <strong>{dbData.cached_queries}</strong></span>
      </div>
      {dbData.queries.map((query, index) => (
        <div key={index} class={`profiler-query-card${query.slow ? ' profiler-query-card--slow' : ''}`}>
          <div class="profiler-query-card__header">
            <span class="profiler-text--muted">#{index + 1}</span>
            <span class={`profiler-query-card__duration ${query.slow ? 'profiler-query-card__duration--slow' : 'profiler-query-card__duration--fast'}`}>
              {query.duration.toFixed(2)} ms
            </span>
          </div>
          <code class="profiler-query-card__code">{query.sql}</code>
        </div>
      ))}
    </>
  )
}
