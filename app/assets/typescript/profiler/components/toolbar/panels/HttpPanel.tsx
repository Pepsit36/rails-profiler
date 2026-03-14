import { HttpData } from '../../../dashboard/types'

interface Props {
  httpData: HttpData
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

export function HttpPanel({ httpData }: Props) {
  const threshold = 500

  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Outbound HTTP
        <span class="profiler-float-right">
          {httpData.total_requests} requests · {httpData.total_duration.toFixed(2)} ms
        </span>
      </div>
      <div class="profiler-toolbar-panel-content">
        {httpData.requests.slice(0, 10).map((req, index) => {
          const isError = req.status >= 400 || req.status === 0
          const isSlow = req.duration >= threshold
          const statusCls = isError ? 'profiler-ajax-card--error' : isSlow ? 'profiler-ajax-card--warning' : 'profiler-ajax-card--success'
          const host = (() => { try { return new URL(req.url).host } catch { return req.url } })()

          return (
            <div key={index} class={`profiler-ajax-card ${statusCls}`}>
              <div class="profiler-ajax-card__row">
                <div class="profiler-flex profiler-flex--gap-2">
                  <span class={`badge ${methodBadgeClass(req.method)}`}>{req.method}</span>
                  <span class="profiler-text--xs profiler-text--truncate">{host}</span>
                </div>
                <div class="profiler-flex profiler-flex--gap-2">
                  <span class={`profiler-text--xs ${isError ? 'profiler-text--error' : 'profiler-text--success'}`}>
                    {req.status === 0 ? 'ERR' : req.status}
                  </span>
                  <span class={`profiler-text--xs ${isSlow ? 'profiler-text--error' : 'profiler-text--muted'}`}>
                    {req.duration.toFixed(2)} ms
                  </span>
                </div>
              </div>
            </div>
          )
        })}
        {httpData.total_requests > 10 && (
          <div class="profiler-more">+ {httpData.total_requests - 10} more</div>
        )}
      </div>
    </>
  )
}
