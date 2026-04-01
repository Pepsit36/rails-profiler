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
  const headers = requestData.headers as Record<string, string> | undefined
  const responseBody = requestData.response_body as string | undefined
  const responseBodyEncoding = requestData.response_body_encoding as string | undefined
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
        {headers && Object.keys(headers).length > 0 && (
          <>
            <div class="profiler-section__header profiler-mt-3">Headers</div>
            {Object.entries(headers).slice(0, 5).map(([key, value]) => (
              <div key={key} class="profiler-toolbar-panel-row">
                <span class="profiler-text--xs profiler-text--mono">{key}</span>
                <strong class="profiler-text--xs profiler-text--mono">
                  {String(value).substring(0, 50)}
                </strong>
              </div>
            ))}
          </>
        )}
        <div class="profiler-section__header profiler-mt-3">Response</div>
        <div class="profiler-toolbar-panel-row">
          <span>Content-Type</span>
          <strong class="profiler-text--xs profiler-text--mono">
            {(profile.response_headers?.['content-type'] as string) || 'N/A'}
          </strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Cache-Control</span>
          <strong class="profiler-text--xs profiler-text--mono">
            {(profile.response_headers?.['cache-control'] as string) || 'N/A'}
          </strong>
        </div>
        {profile.response_headers && Object.entries(profile.response_headers)
          .filter(([k]) => !['content-type', 'cache-control'].includes(k))
          .slice(0, 8)
          .map(([key, value]) => (
            <div key={key} class="profiler-toolbar-panel-row">
              <span class="profiler-text--xs profiler-text--mono">{key}</span>
              <strong class="profiler-text--xs profiler-text--mono">
                {String(value).substring(0, 60)}
              </strong>
            </div>
          ))
        }
        {responseBody && responseBodyEncoding !== 'base64' && (
          <>
            <div class="profiler-section__header profiler-mt-3">Response Body</div>
            <pre style="margin:0;padding:6px 0;font-size:10px;line-height:1.5;white-space:pre-wrap;word-break:break-all;color:var(--pf-text,#eef2f7);max-height:120px;overflow:hidden;">
              {responseBody.substring(0, 300)}{responseBody.length > 300 ? '…' : ''}
            </pre>
          </>
        )}
        {responseBody && responseBodyEncoding === 'base64' && (
          <>
            <div class="profiler-section__header profiler-mt-3">Response Body</div>
            <div class="profiler-toolbar-panel-row">
              <span class="profiler-text--xs profiler-text--mono">[binary]</span>
            </div>
          </>
        )}
      </div>
    </>
  )
}
