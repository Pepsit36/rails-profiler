import { useState } from 'preact/hooks'
import { Profile, RequestData } from '../../../dashboard/types'

interface Props {
  profile: Profile
}

function tryFormatJson(text: string): string {
  try {
    return JSON.stringify(JSON.parse(text), null, 2)
  } catch {
    return text
  }
}

function BodyBlock({ body, encoding }: { body?: string; encoding?: string }) {
  if (!body) return null
  if (encoding === 'base64') {
    return <p class="profiler-text--muted profiler-text--sm">[binary content, base64-encoded]</p>
  }
  const formatted = tryFormatJson(body)
  return <pre class="profiler-code profiler-text--xs">{formatted}</pre>
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

export function RequestTab({ profile }: Props) {
  const [copied, setCopied] = useState(false)
  const curl = buildCurl(profile)
  const routeData = (profile.collectors_data?.request ?? {}) as RequestData

  function copyToClipboard() {
    navigator.clipboard.writeText(curl).then(() => {
      setCopied(true)
      setTimeout(() => setCopied(false), 2000)
    })
  }

  return (
    <>
      <h2 class="profiler-section__header">Request</h2>
      <table>
        <tr>
          <th class="profiler-text--sm" style="width: 200px;">Path</th>
          <td>{profile.path}</td>
        </tr>
        <tr>
          <th class="profiler-text--sm">Method</th>
          <td>{profile.method}</td>
        </tr>
        <tr>
          <th class="profiler-text--sm">Status</th>
          <td>{profile.status}</td>
        </tr>
        <tr>
          <th class="profiler-text--sm">Duration</th>
          <td>{profile.duration.toFixed(2)} ms</td>
        </tr>
        {routeData.controller_action && (
          <tr>
            <th class="profiler-text--sm">Controller#Action</th>
            <td class="profiler-text--mono profiler-text--xs">{routeData.controller_action}</td>
          </tr>
        )}
        {routeData.route_name && (
          <tr>
            <th class="profiler-text--sm">Route Name</th>
            <td class="profiler-text--mono profiler-text--xs">{routeData.route_name}</td>
          </tr>
        )}
        {routeData.route_pattern && (
          <tr>
            <th class="profiler-text--sm">Route Pattern</th>
            <td class="profiler-text--mono profiler-text--xs">{routeData.route_pattern}</td>
          </tr>
        )}
        {routeData.route_params && Object.keys(routeData.route_params).length > 0 && (
          <tr>
            <th class="profiler-text--sm">Route Params</th>
            <td class="profiler-text--mono profiler-text--xs">
              {Object.entries(routeData.route_params).map(([k, v]) => `${k}: ${v}`).join(', ')}
            </td>
          </tr>
        )}
      </table>

      {profile.headers && Object.keys(profile.headers).length > 0 && (
        <>
          <h2 class="profiler-section__header profiler-mt-6">Request Headers</h2>
          <table>
            {Object.entries(profile.headers).map(([k, v]) => (
              <tr key={k}>
                <th class="profiler-text--sm" style="width: 200px;">{k}</th>
                <td class="profiler-text--mono profiler-text--xs">{String(v)}</td>
              </tr>
            ))}
          </table>
        </>
      )}

      {profile.params && Object.keys(profile.params).length > 0 && (
        <>
          <h2 class="profiler-section__header profiler-mt-6">Request Params</h2>
          <pre class="profiler-code profiler-text--xs">{JSON.stringify(profile.params, null, 2)}</pre>
        </>
      )}

      {profile.request_body && (
        <>
          <h2 class="profiler-section__header profiler-mt-6">Request Body</h2>
          <BodyBlock body={profile.request_body} encoding={profile.request_body_encoding} />
        </>
      )}

      {profile.response_headers && Object.keys(profile.response_headers).length > 0 && (
        <>
          <h2 class="profiler-section__header profiler-mt-6">Response Headers</h2>
          <table>
            {Object.entries(profile.response_headers).map(([k, v]) => (
              <tr key={k}>
                <th class="profiler-text--sm" style="width: 200px;">{k}</th>
                <td class="profiler-text--mono profiler-text--xs">{String(v)}</td>
              </tr>
            ))}
          </table>
        </>
      )}

      {profile.response_body && (
        <>
          <h2 class="profiler-section__header profiler-mt-6">Response Body</h2>
          <BodyBlock body={profile.response_body} encoding={profile.response_body_encoding} />
        </>
      )}

      <h2 class="profiler-section__header profiler-mt-6">Curl Command</h2>
      <div style="position: relative;">
        <button
          onClick={copyToClipboard}
          class="profiler-body-download-btn"
          style="position: absolute; top: 8px; right: 8px; z-index: 1;"
        >
          {copied ? 'Copied!' : 'Copy'}
        </button>
        <pre class="profiler-code profiler-text--xs" style="padding-right: 80px;">{curl}</pre>
      </div>
    </>
  )
}
