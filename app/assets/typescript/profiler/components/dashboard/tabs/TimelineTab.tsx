import { PerformanceData } from '../../../dashboard/types'

interface Props {
  perfData: PerformanceData | undefined
}

export function TimelineTab({ perfData }: Props) {
  if (!perfData?.events) {
    return (
      <div class="profiler-empty">
        <p class="profiler-empty__description">No performance events recorded</p>
      </div>
    )
  }

  return (
    <>
      <h2 class="profiler-section__header">
        Performance Timeline ({perfData.total_events} events)
      </h2>
      <p class="profiler-mb-4">Total Duration: <strong>{perfData.total_duration} ms</strong></p>
      {perfData.events.map((event, index) => (
        <div key={index} class="profiler-query-card">
          <div class="profiler-query-card__header">
            <strong>{event.name}</strong>
            <span class={event.duration >= 500 ? 'badge-error' : event.duration >= 100 ? 'badge-warning' : 'badge-success'}>{event.duration.toFixed(2)} ms</span>
          </div>
          {event.payload && Object.keys(event.payload).length > 0 && (
            <pre class="profiler-text--xs profiler-text--muted profiler-mt-2">
              {JSON.stringify(event.payload, null, 2)}
            </pre>
          )}
        </div>
      ))}
    </>
  )
}
