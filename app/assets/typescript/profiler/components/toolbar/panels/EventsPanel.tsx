import { PerformanceData } from '../../../dashboard/types'

interface Props {
  perfData: PerformanceData
}

export function EventsPanel({ perfData }: Props) {
  return (
    <>
      <div class="profiler-toolbar-panel-header">Events</div>
      <div class="profiler-toolbar-panel-content">
        {perfData.events.slice(0, 8).map((event, index) => (
          <div key={index} class="profiler-toolbar-panel-row">
            <span class="profiler-text--xs">{event.name}</span>
            <strong class="profiler-text--accent">{event.duration.toFixed(2)} ms</strong>
          </div>
        ))}
      </div>
    </>
  )
}
