import { DatabaseData } from '../../../dashboard/types'

interface Props {
  dbData: DatabaseData
}

export function DatabasePanel({ dbData }: Props) {
  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Database
        <span class="profiler-float-right">
          {dbData.total_queries} queries · {dbData.total_duration.toFixed(2)} ms
        </span>
      </div>
      <div class="profiler-toolbar-panel-content">
        {dbData.queries.slice(0, 10).map((query, index) => (
          <div
            key={index}
            class={`profiler-toolbar-panel-query${query.slow ? ' profiler-toolbar-panel-query-slow' : ''}`}
          >
            <div class="profiler-flex profiler-flex--between profiler-mb-1">
              <span class="profiler-text--xs profiler-text--muted">
                #{index + 1} {query.name}
              </span>
              <span class={`${query.slow ? 'profiler-text--error' : 'profiler-text--success'} profiler-text--xs`}>
                {query.duration.toFixed(2)} ms
              </span>
            </div>
            <code>{query.sql}</code>
          </div>
        ))}
        {dbData.total_queries > 10 && (
          <div class="profiler-more">+ {dbData.total_queries - 10} more queries</div>
        )}
      </div>
    </>
  )
}
