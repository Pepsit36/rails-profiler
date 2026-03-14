import { useState, useEffect } from 'preact/hooks'
import { Profile } from '../dashboard/types'

const BASE = '/_profiler'

function statusBadge(status: number): string {
  if (status >= 200 && status < 300) return 'badge-success'
  if (status >= 300 && status < 400) return 'badge-info'
  if (status >= 400 && status < 500) return 'badge-warning'
  if (status >= 500) return 'badge-error'
  return 'badge-info'
}

function durationBadge(duration: number): string {
  if (duration > 1000) return 'badge-error'
  if (duration > 500) return 'badge-warning'
  return 'badge-success'
}

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('en', { hour12: false })
}

function formatMemory(bytes?: number): string {
  if (!bytes) return '-'
  return (bytes / 1024 / 1024).toFixed(2) + ' MB'
}

export function ProfileList() {
  const [profiles, setProfiles] = useState<Profile[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    fetch(`${BASE}/api/profiles`)
      .then(res => res.json())
      .then(data => {
        setProfiles(data)
        setLoading(false)
      })
      .catch(() => {
        setError('Failed to load profiles')
        setLoading(false)
      })
  }, [])

  if (loading) {
    return (
      <div class="container">
        <div class="header">
          <h1>🔍 Rails Profiler</h1>
          <p>Recent profiled requests</p>
        </div>
        <div class="profiler-empty">
          <div class="profiler-empty__title">Loading...</div>
        </div>
      </div>
    )
  }

  if (error) {
    return (
      <div class="container">
        <div class="header">
          <h1>🔍 Rails Profiler</h1>
        </div>
        <div class="profiler-empty">
          <div class="profiler-empty__title">{error}</div>
        </div>
      </div>
    )
  }

  return (
    <div class="container">
      <div class="header">
        <h1>🔍 Rails Profiler</h1>
        <p>Recent profiled requests</p>
      </div>
      {profiles.length === 0 ? (
        <div class="profiler-empty">
          <div class="profiler-empty__title">No profiles found</div>
          <p class="profiler-empty__description">Make some requests to your application to see profiling data</p>
        </div>
      ) : (
        <table>
          <thead>
            <tr>
              <th>Time</th>
              <th>Method</th>
              <th>Path</th>
              <th>Duration</th>
              <th>Memory</th>
              <th>Status</th>
              <th>Token</th>
            </tr>
          </thead>
          <tbody>
            {profiles.map(p => (
              <tr key={p.token}>
                <td>{formatTime(p.started_at)}</td>
                <td><span class="badge badge-info">{p.method}</span></td>
                <td><a href={`${BASE}/profiles/${p.token}`}>{p.path}</a></td>
                <td>
                  <span class={`badge ${durationBadge(p.duration)}`}>{p.duration.toFixed(2)} ms</span>
                </td>
                <td>{formatMemory(p.memory)}</td>
                <td><span class={`badge ${statusBadge(p.status)}`}>{p.status}</span></td>
                <td class="profiler-text--xs profiler-text--mono profiler-text--muted">
                  {p.token.substring(0, 8)}...
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}
