import { Profile } from '../../../dashboard/types'

interface Props {
  profile: Profile
  requestData: Record<string, any>
}

function statusClass(status: number): string {
  if (status >= 200 && status < 300) return 'profiler-text--success'
  if (status >= 300 && status < 400) return 'profiler-text--warning'
  if (status >= 400) return 'profiler-text--error'
  return ''
}

export function RequestPanel({ profile, requestData }: Props) {
  const cls = statusClass(profile.status)
  const controllerAction = requestData.controller_action as string | undefined
  const routeName = requestData.route_name as string | undefined
  const routePattern = requestData.route_pattern as string | undefined
  const routeParams = requestData.route_params as Record<string, string> | undefined

  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Request &amp; Response
        <span class="profiler-float-right">{profile.path}</span>
      </div>
      <div class="profiler-toolbar-panel-content">
        <div class="profiler-section__header">Request</div>
        <div class="profiler-toolbar-panel-row">
          <span>Method</span>
          <strong class="profiler-text--accent">{profile.method}</strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Path</span>
          <strong>{profile.path}</strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Status</span>
          <strong class={cls}>{profile.status}</strong>
        </div>
        {controllerAction && (
          <div class="profiler-toolbar-panel-row">
            <span>Controller#Action</span>
            <strong class="profiler-text--xs profiler-text--mono">{controllerAction}</strong>
          </div>
        )}
        {routeName && (
          <div class="profiler-toolbar-panel-row">
            <span>Route Name</span>
            <strong class="profiler-text--xs profiler-text--mono">{routeName}</strong>
          </div>
        )}
        {routePattern && (
          <div class="profiler-toolbar-panel-row">
            <span>Route Pattern</span>
            <strong class="profiler-text--xs profiler-text--mono">{routePattern}</strong>
          </div>
        )}
        {routeParams && Object.keys(routeParams).length > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span>Route Params</span>
            <strong class="profiler-text--xs profiler-text--mono">
              {Object.entries(routeParams).map(([k, v]) => `${k}: ${v}`).join(', ')}
            </strong>
          </div>
        )}
        {profile.params && Object.keys(profile.params).length > 0 && (
          <>
            <div class="profiler-section__header profiler-mt-3">Parameters</div>
            {Object.entries(profile.params).map(([key, value]) => (
              <div key={key} class="profiler-toolbar-panel-row">
                <span class="profiler-text--xs profiler-text--mono">{key}</span>
                <strong class="profiler-text--xs profiler-text--mono">
                  {String(value).substring(0, 40)}
                </strong>
              </div>
            ))}
          </>
        )}
      </div>
    </>
  )
}
