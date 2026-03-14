import { AjaxData } from '../../../dashboard/types'

interface Props {
  ajaxData: AjaxData
}

function methodBadgeClass(method: string): string {
  const map: Record<string, string> = {
    GET: 'badge-info',
    POST: 'badge-success',
    PUT: 'badge-warning',
    PATCH: 'badge-warning',
    DELETE: 'badge-error',
  }
  return map[method] || ''
}

export function AjaxPanel({ ajaxData }: Props) {
  return (
    <>
      <div class="profiler-toolbar-panel-header">
        AJAX
        <span class="profiler-float-right">
          {ajaxData.total_requests} requests · {ajaxData.total_duration.toFixed(2)} ms
        </span>
      </div>
      <div class="profiler-toolbar-panel-content">
        {ajaxData.requests.slice(0, 10).map((req, index) => {
          const statusCls = req.status >= 200 && req.status < 300
            ? 'profiler-ajax-card--success'
            : 'profiler-ajax-card--error'
          return (
            <div key={index} class={`profiler-ajax-card ${statusCls}`}>
              <div class="profiler-ajax-card__row">
                <div class="profiler-flex profiler-flex--gap-2">
                  <span class={`badge ${methodBadgeClass(req.method)}`}>{req.method}</span>
                  <span class="profiler-text--xs profiler-text--truncate">{req.path}</span>
                </div>
                <div class="profiler-flex profiler-flex--gap-2">
                  <span class={`profiler-text--xs ${req.status >= 200 && req.status < 300 ? 'profiler-text--success' : 'profiler-text--error'}`}>
                    {req.status}
                  </span>
                  <span class="profiler-text--xs profiler-text--muted">
                    {req.duration.toFixed(2)} ms
                  </span>
                </div>
              </div>
            </div>
          )
        })}
        {ajaxData.total_requests > 10 && (
          <div class="profiler-more">+ {ajaxData.total_requests - 10} more</div>
        )}
      </div>
    </>
  )
}
