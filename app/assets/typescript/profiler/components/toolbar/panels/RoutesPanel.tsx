import { RoutesData } from '../../../dashboard/types'

interface Props {
  routesData: RoutesData
}

export function RoutesPanel({ routesData }: Props) {
  const { total, matched } = routesData

  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Routes
        <span class="profiler-float-right">{total} routes</span>
      </div>
      <div class="profiler-toolbar-panel-content">
        {matched ? (
          <>
            <div class="profiler-section__header">Matched Route</div>
            <div class="profiler-toolbar-panel-row">
              <span>Pattern</span>
              <strong class="profiler-text--xs profiler-text--mono">{matched.pattern}</strong>
            </div>
            {matched.name && (
              <div class="profiler-toolbar-panel-row">
                <span>Name</span>
                <strong class="profiler-text--xs profiler-text--mono">{matched.name}_path</strong>
              </div>
            )}
            {matched.controller_action && (
              <div class="profiler-toolbar-panel-row">
                <span>Controller#Action</span>
                <strong class="profiler-text--xs profiler-text--mono">{matched.controller_action}</strong>
              </div>
            )}
          </>
        ) : (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--muted">No route matched</span>
          </div>
        )}
      </div>
    </>
  )
}
