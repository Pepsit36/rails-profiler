import { AjaxData } from '../../../dashboard/types'

interface Props {
  ajaxData: AjaxData | undefined
}

function methodBadge(method: string): string {
  const map: Record<string, string> = { GET: 'info', POST: 'success', PUT: 'warning', PATCH: 'warning', DELETE: 'error' }
  return map[method] || 'default'
}

function statusBadge(status: number): string {
  if (status >= 200 && status < 300) return 'success'
  if (status >= 400) return 'error'
  return 'warning'
}

export function AjaxTab({ ajaxData }: Props) {
  if (!ajaxData?.requests?.length) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">🌐</div>
        <h3 class="profiler-empty__title">No AJAX requests tracked</h3>
        <p class="profiler-empty__description">AJAX requests made from this page will appear here.</p>
      </div>
    )
  }

  const avgDuration = ajaxData.total_duration / ajaxData.total_requests

  return (
    <>
      <h2 class="profiler-section__header">AJAX Requests ({ajaxData.total_requests})</h2>
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Total Duration: <strong>{ajaxData.total_duration.toFixed(2)} ms</strong></span>
        <span>Average: <strong>{avgDuration.toFixed(2)} ms</strong></span>
      </div>

      <div class="profiler-grid profiler-grid--2 profiler-mb-6">
        <div class="profiler-panel profiler-panel--sm">
          <h3 class="profiler-text--sm profiler-text--muted profiler-text--uppercase profiler-mb-3">By Method</h3>
          {Object.entries(ajaxData.by_method).map(([method, count]) => (
            <div key={method} class="profiler-kv-row">
              <span class={`badge badge-${methodBadge(method)}`}>{method}</span>
              <strong>{count}</strong>
            </div>
          ))}
        </div>
        <div class="profiler-panel profiler-panel--sm">
          <h3 class="profiler-text--sm profiler-text--muted profiler-text--uppercase profiler-mb-3">By Status</h3>
          {Object.entries(ajaxData.by_status).map(([status, count]) => (
            <div key={status} class="profiler-kv-row">
              <span class={`badge badge-${status.startsWith('2') ? 'success' : (status.startsWith('4') || status.startsWith('5')) ? 'error' : 'warning'}`}>
                {status}
              </span>
              <strong>{count}</strong>
            </div>
          ))}
        </div>
      </div>

      <h3 class="profiler-text--lg profiler-mb-3">Requests</h3>
      {ajaxData.requests.map((req, index) => (
        <div key={index} class={`profiler-ajax-card profiler-ajax-card--${req.status >= 200 && req.status < 300 ? 'success' : 'error'}`}>
          <div class="profiler-ajax-card__row">
            <div class="profiler-flex profiler-flex--gap-3">
              <span class={`profiler-ajax-card__method badge badge-${methodBadge(req.method)}`}>{req.method}</span>
              <strong class="profiler-ajax-card__path">{req.path}</strong>
            </div>
            <div class="profiler-flex profiler-flex--gap-2">
              <span class={`badge badge-${statusBadge(req.status)}`}>{req.status}</span>
              <span class="badge badge-info">{req.duration.toFixed(2)} ms</span>
            </div>
          </div>
          <div class="profiler-ajax-card__row">
            <span class="profiler-ajax-card__time">
              {new Date(req.started_at).toLocaleTimeString('en', { hour12: false })}
            </span>
            <a href={`/_profiler/profiles/${req.token}`} class="profiler-text--sm" style="color: var(--profiler-accent);">
              View Profile →
            </a>
          </div>
        </div>
      ))}
    </>
  )
}
