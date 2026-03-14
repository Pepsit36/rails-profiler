import { ViewData } from '../../../dashboard/types'

interface Props {
  viewData: ViewData
}

export function ViewsPanel({ viewData }: Props) {
  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Views
        <span class="profiler-float-right">{viewData.total_duration.toFixed(2)} ms</span>
      </div>
      <div class="profiler-toolbar-panel-content">
        {viewData.views && viewData.views.length > 0 && (
          <>
            <div class="profiler-section__header">Templates</div>
            {viewData.views.map((view, i) => (
              <div key={i} class="profiler-toolbar-panel-row">
                <span class="profiler-text--xs">{view.identifier}</span>
                <strong class="profiler-text--success">{view.duration.toFixed(2)} ms</strong>
              </div>
            ))}
          </>
        )}
        {viewData.partials && viewData.partials.length > 0 && (
          <>
            <div class="profiler-section__header profiler-mt-3">Partials</div>
            {viewData.partials.map((partial, i) => (
              <div key={i} class="profiler-toolbar-panel-row">
                <span class="profiler-text--xs">{partial.identifier}</span>
                <strong class="profiler-text--success">{partial.duration.toFixed(2)} ms</strong>
              </div>
            ))}
          </>
        )}
      </div>
    </>
  )
}
