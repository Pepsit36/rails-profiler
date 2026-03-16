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
  const [section, setSection] = useState<'http' | 'jobs'>('http')
  const [profiles, setProfiles] = useState<Profile[]>([])
  const [jobs, setJobs] = useState<Profile[]>([])
  const [loadingHttp, setLoadingHttp] = useState(true)
  const [loadingJobs, setLoadingJobs] = useState(false)
  const [jobsLoaded, setJobsLoaded] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [jobsError, setJobsError] = useState<string | null>(null)

  useEffect(() => {
    fetch(`${BASE}/api/profiles`)
      .then(res => res.json())
      .then(data => {
        setProfiles(data.filter((p: Profile) => p.profile_type !== 'job'))
        setLoadingHttp(false)
      })
      .catch(() => {
        setError('Failed to load profiles')
        setLoadingHttp(false)
      })
  }, [])

  const loadJobs = () => {
    if (jobsLoaded) return
    setLoadingJobs(true)
    fetch(`${BASE}/api/jobs`)
      .then(res => res.json())
      .then(data => {
        setJobs(data)
        setLoadingJobs(false)
        setJobsLoaded(true)
      })
      .catch(() => {
        setJobsError('Failed to load job profiles')
        setLoadingJobs(false)
        setJobsLoaded(true)
      })
  }

  const handleSectionChange = (s: 'http' | 'jobs') => {
    setSection(s)
    if (s === 'jobs') loadJobs()
  }

  const tabClass = (s: 'http' | 'jobs') => `tab${section === s ? ' active' : ''}`

  return (
    <div class="container">
      <div class="header">
        <h1>🔍 Rails Profiler</h1>
        <p>Recent profiled requests and jobs</p>
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          <a href="#" class={tabClass('http')} onClick={e => { e.preventDefault(); handleSectionChange('http') }}>HTTP Requests</a>
          <a href="#" class={tabClass('jobs')} onClick={e => { e.preventDefault(); handleSectionChange('jobs') }}>Background Jobs</a>
        </div>

        <div class="profiler-p-4 tab-content active">
          {section === 'http' && (
            loadingHttp ? (
              <div class="profiler-empty"><div class="profiler-empty__title">Loading...</div></div>
            ) : error ? (
              <div class="profiler-empty"><div class="profiler-empty__title">{error}</div></div>
            ) : profiles.length === 0 ? (
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
                      <td><span class={`badge ${durationBadge(p.duration)}`}>{p.duration.toFixed(2)} ms</span></td>
                      <td>{formatMemory(p.memory)}</td>
                      <td><span class={`badge ${statusBadge(p.status)}`}>{p.status}</span></td>
                      <td class="profiler-text--xs profiler-text--mono profiler-text--muted">{p.token.substring(0, 8)}...</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )
          )}

          {section === 'jobs' && (
            loadingJobs ? (
              <div class="profiler-empty"><div class="profiler-empty__title">Loading...</div></div>
            ) : jobsError ? (
              <div class="profiler-empty"><div class="profiler-empty__title">{jobsError}</div></div>
            ) : jobs.length === 0 ? (
              <div class="profiler-empty">
                <div class="profiler-empty__title">No job profiles found</div>
                <p class="profiler-empty__description">Run background jobs in your application to see profiling data</p>
              </div>
            ) : (
              <table>
                <thead>
                  <tr>
                    <th>Time</th>
                    <th>Job Class</th>
                    <th>Queue</th>
                    <th>Duration</th>
                    <th>Status</th>
                    <th>Executions</th>
                    <th>Token</th>
                  </tr>
                </thead>
                <tbody>
                  {jobs.map(p => {
                    const jobData = p.collectors_data?.job as any
                    const isFailed = p.status === 500
                    return (
                      <tr key={p.token}>
                        <td>{formatTime(p.started_at)}</td>
                        <td><a href={`${BASE}/profiles/${p.token}`}>{p.path}</a></td>
                        <td><span class="profiler-text--xs profiler-text--mono">{jobData?.queue || '-'}</span></td>
                        <td><span class={`badge ${durationBadge(p.duration)}`}>{p.duration.toFixed(2)} ms</span></td>
                        <td><span class={`badge badge-${isFailed ? 'error' : 'success'}`}>{isFailed ? '✗ Failed' : '✓ Completed'}</span></td>
                        <td>{jobData?.executions ?? '-'}</td>
                        <td class="profiler-text--xs profiler-text--mono profiler-text--muted">{p.token.substring(0, 8)}...</td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            )
          )}
        </div>
      </div>
    </div>
  )
}
