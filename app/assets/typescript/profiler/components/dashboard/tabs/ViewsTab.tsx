import { ViewData } from '../../../dashboard/types'

interface Props {
  viewData: ViewData | undefined
}

export function ViewsTab({ viewData }: Props) {
  if (!viewData) {
    return (
      <div class="profiler-empty">
        <p class="profiler-empty__description">No view data recorded</p>
      </div>
    )
  }

  return (
    <>
      <h2 class="profiler-section__header">View Rendering</h2>
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Views: <strong>{viewData.total_views}</strong></span>
        <span>Partials: <strong>{viewData.total_partials}</strong></span>
        <span>Total Duration: <strong>{viewData.total_duration} ms</strong></span>
      </div>
      {viewData.views && viewData.views.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-6 profiler-mb-3">Templates</h3>
          {viewData.views.map((view, i) => (
            <div key={i} class="profiler-query-card profiler-query-card--success">
              <div class="profiler-query-card__header">
                <span>{view.identifier}</span>
                <span class="badge-success">{view.duration.toFixed(2)} ms</span>
              </div>
            </div>
          ))}
        </>
      )}
      {viewData.partials && viewData.partials.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-6 profiler-mb-3">Partials</h3>
          {viewData.partials.map((partial, i) => (
            <div key={i} class="profiler-query-card profiler-query-card--success">
              <div class="profiler-query-card__header">
                <span>{partial.identifier}</span>
                <span class="badge-success">{partial.duration.toFixed(2)} ms</span>
              </div>
            </div>
          ))}
        </>
      )}
    </>
  )
}
