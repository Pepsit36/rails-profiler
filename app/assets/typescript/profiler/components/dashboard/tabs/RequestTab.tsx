import { Profile, RequestData } from '../../../dashboard/types'
import { HttpCardHeader, HttpReqRespDetail } from './shared/HttpComponents'

interface Props {
  profile: Profile
}

function buildCurl(profile: Profile): string {
  const headers = profile.headers ?? {}
  const params = profile.params ?? {}
  const reqBody = profile.request_body

  const parts: string[] = [`curl -X ${profile.method}`]

  Object.entries(headers)
    .filter(([k]) => k !== 'User-Agent')
    .forEach(([k, v]) => parts.push(`  -H '${k}: ${v}'`))

  if (['POST', 'PUT', 'PATCH'].includes(profile.method)) {
    if (reqBody && reqBody.length > 0) {
      parts.push(`  -d '${reqBody.replace(/'/g, "'\\''")}'`)
    } else if (Object.keys(params).length > 0) {
      const ct = (headers['Content-Type'] ?? '') as string
      if (ct.includes('application/json')) {
        parts.push(`  -d '${JSON.stringify(params).replace(/'/g, "'\\''")}'`)
      } else {
        Object.entries(params).forEach(([k, v]) =>
          parts.push(`  --data-urlencode '${k}=${v}'`)
        )
      }
    }
  }

  let url = `http://localhost:3000${profile.path}`
  if (profile.method === 'GET' && Object.keys(params).length > 0) {
    url += '?' + Object.entries(params)
      .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`)
      .join('&')
  }

  parts.push(`  '${url}'`)
  return parts.join(' \\\n')
}

// Bodies are kept up to max_captured_body_bytes. The flags are on the profile, and in the
// request collector's data for the stores that rebuild a profile from it.
function truncationNotes(profile: Profile, routeData: RequestData): string[] {
  const notes: string[] = []
  const describe = (what: string, truncated?: boolean | null, size?: number | null, minimum?: boolean | null) => {
    if (truncated) {
      const total = size != null ? `${minimum ? 'at least ' : ''}${size.toLocaleString('en')} bytes, ` : ''
      notes.push(`${what} body truncated: ${total}only the beginning was kept (max_captured_body_bytes).`)
    }
  }
  describe('Request', profile.request_body_truncated ?? routeData.request_body_truncated,
    profile.request_body_size ?? routeData.request_body_size,
    profile.request_body_size_is_minimum ?? routeData.request_body_size_is_minimum)
  describe('Response', profile.response_body_truncated ?? routeData.response_body_truncated,
    profile.response_body_size ?? routeData.response_body_size,
    profile.response_body_size_is_minimum ?? routeData.response_body_size_is_minimum)
  return notes
}

export function RequestTab({ profile }: Props) {
  const routeData = (profile.collectors_data?.request ?? {}) as RequestData
  const hasParams = profile.params && Object.keys(profile.params).length > 0
  const notes = truncationNotes(profile, routeData)

  return (
    <div class="profiler-ajax-card profiler-ajax-card--success" style="margin-bottom:8px;background:var(--profiler-bg-elevated);transform:translateX(3px);box-shadow:var(--profiler-shadow-sm);transition:none">

      <HttpCardHeader
        method={profile.method}
        url={profile.path}
        copyUrl={`http://localhost:3000${profile.path}`}
        status={profile.status}
        duration={profile.duration}
        curlCommand={buildCurl(profile)}
      />

      {(routeData.controller_action || routeData.route_pattern) && (
        <div class="profiler-ajax-card__row">
          {routeData.controller_action && (
            <span class="profiler-text--xs profiler-text--muted" style="margin-right:16px">
              {routeData.controller_action}
            </span>
          )}
          {routeData.route_pattern && (
            <span class="profiler-text--xs profiler-text--muted" style="font-family:monospace">
              {routeData.route_name ? `${routeData.route_name} · ` : ''}{routeData.route_pattern}
            </span>
          )}
        </div>
      )}

      {notes.map(note => (
        <div class="profiler-ajax-card__row profiler-text--xs profiler-text--warning" key={note}>{note}</div>
      ))}

      <HttpReqRespDetail
        request={{
          headers: (profile.headers ?? {}) as Record<string, string>,
          body: profile.request_body ?? undefined,
          body_encoding: profile.request_body_encoding as 'text' | 'base64' | undefined,
          params: hasParams ? profile.params as Record<string, unknown> : undefined,
        }}
        response={{
          headers: (profile.response_headers ?? {}) as Record<string, string>,
          body: profile.response_body ?? undefined,
          body_encoding: profile.response_body_encoding as 'text' | 'base64' | undefined,
        }}
      />
    </div>
  )
}
