import { useState, useEffect } from 'preact/hooks'
import { Profile, HttpRequest } from '../dashboard/types'
import { HttpRequestDetail } from './dashboard/tabs/HttpTab'

const BASE = '/_profiler'

interface OutboundRequest extends HttpRequest {
  profile_token: string
  profile_started_at: string
}

function methodClass(method: string): string {
  const map: Record<string, string> = { GET: 'badge-info', POST: 'badge-success', PUT: 'badge-warning', PATCH: 'badge-warning', DELETE: 'badge-error' }
  return map[method] || 'badge-default'
}

function statusClass(status: number): string {
  if (status >= 200 && status < 300) return 'badge-success'
  if (status >= 300 && status < 400) return 'badge-info'
  if (status >= 400 && status < 500) return 'badge-warning'
  if (status >= 500) return 'badge-error'
  return 'badge-default'
}

function durationClass(duration: number): string {
  if (duration >= 500) return 'badge-error'
  if (duration >= 100) return 'badge-warning'
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
  const initialSection = (): 'http' | 'jobs' | 'outbound' => {
    const s = new URLSearchParams(window.location.search).get('section')
    return (s === 'http' || s === 'jobs' || s === 'outbound') ? s : 'http'
  }
  const [section, setSection] = useState<'http' | 'jobs' | 'outbound'>(initialSection)
  const [profiles, setProfiles] = useState<Profile[]>([])
  const [jobs, setJobs] = useState<Profile[]>([])
  const [outboundRequests, setOutboundRequests] = useState<OutboundRequest[]>([])
  const [loadingHttp, setLoadingHttp] = useState(true)
  const [loadingJobs, setLoadingJobs] = useState(false)
  const [loadingOutbound, setLoadingOutbound] = useState(false)
  const [jobsLoaded, setJobsLoaded] = useState(false)
  const [outboundLoaded, setOutboundLoaded] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [jobsError, setJobsError] = useState<string | null>(null)
  const [outboundError, setOutboundError] = useState<string | null>(null)
  const [copiedToken, setCopiedToken] = useState<string | null>(null)

  // HTTP filters
  const [httpSearch, setHttpSearch] = useState('')
  const [httpMethod, setHttpMethod] = useState('')
  const [httpStatus, setHttpStatus] = useState('')
  const [httpDuration, setHttpDuration] = useState('')
  // Jobs filters
  const [jobSearch, setJobSearch] = useState('')
  const [jobStatus, setJobStatus] = useState('')
  const [jobDuration, setJobDuration] = useState('')
  // Outbound filters
  const [outboundSearch, setOutboundSearch] = useState('')
  const [outboundMethod, setOutboundMethod] = useState('')
  const [outboundStatus, setOutboundStatus] = useState('')

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

  useEffect(() => {
    if (section === 'jobs') loadJobs()
    if (section === 'outbound') loadOutbound()
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

  const loadOutbound = () => {
    if (outboundLoaded) return
    setLoadingOutbound(true)
    fetch(`${BASE}/api/outbound_http`)
      .then(res => res.json())
      .then(data => {
        setOutboundRequests(data)
        setLoadingOutbound(false)
        setOutboundLoaded(true)
      })
      .catch(() => {
        setOutboundError('Failed to load outbound HTTP requests')
        setLoadingOutbound(false)
        setOutboundLoaded(true)
      })
  }

  const handleSectionChange = (s: 'http' | 'jobs' | 'outbound') => {
    setSection(s)
    const url = new URL(window.location.href)
    url.searchParams.set('section', s)
    history.pushState(null, '', url.toString())
    if (s === 'jobs') loadJobs()
    if (s === 'outbound') loadOutbound()
    // Reset all filters
    setHttpSearch(''); setHttpMethod(''); setHttpStatus(''); setHttpDuration('')
    setJobSearch(''); setJobStatus(''); setJobDuration('')
    setOutboundSearch(''); setOutboundMethod(''); setOutboundStatus('')
  }

  const copyToken = (token: string) => {
    navigator.clipboard.writeText(token).then(() => {
      setCopiedToken(token)
      setTimeout(() => setCopiedToken(null), 1500)
    })
  }

  const deleteProfile = (token: string) => {
    fetch(`${BASE}/api/profiles/${token}`, { method: 'DELETE' }).then(() => {
      setProfiles(prev => prev.filter(p => p.token !== token))
    })
  }

  const deleteJob = (token: string) => {
    fetch(`${BASE}/api/jobs/${token}`, { method: 'DELETE' }).then(() => {
      setJobs(prev => prev.filter(p => p.token !== token))
    })
  }

  const clearProfiles = () => {
    fetch(`${BASE}/api/profiles/clear`, { method: 'DELETE' }).then(() => {
      setProfiles([])
    })
  }

  const clearJobs = () => {
    fetch(`${BASE}/api/jobs/clear`, { method: 'DELETE' }).then(() => {
      setJobs([])
    })
  }

  const refresh = () => {
    if (section === 'http') {
      setLoadingHttp(true)
      fetch(`${BASE}/api/profiles`)
        .then(res => res.json())
        .then(data => { setProfiles(data.filter((p: Profile) => p.profile_type !== 'job')); setLoadingHttp(false) })
        .catch(() => { setError('Failed to load profiles'); setLoadingHttp(false) })
    } else if (section === 'jobs') {
      setLoadingJobs(true)
      fetch(`${BASE}/api/jobs`)
        .then(res => res.json())
        .then(data => { setJobs(data); setLoadingJobs(false) })
        .catch(() => { setJobsError('Failed to load job profiles'); setLoadingJobs(false) })
    } else {
      setLoadingOutbound(true)
      fetch(`${BASE}/api/outbound_http`)
        .then(res => res.json())
        .then(data => { setOutboundRequests(data); setLoadingOutbound(false) })
        .catch(() => { setOutboundError('Failed to load outbound HTTP requests'); setLoadingOutbound(false) })
    }
  }

  const tabClass = (s: 'http' | 'jobs' | 'outbound') => `tab${section === s ? ' active' : ''}`

  // Computed filtered arrays
  const filteredProfiles = profiles.filter(p => {
    if (httpSearch && !p.path.toLowerCase().includes(httpSearch.toLowerCase())) return false
    if (httpMethod && p.method !== httpMethod) return false
    if (httpStatus) {
      const base = parseInt(httpStatus)
      if (!(p.status >= base && p.status < base + 100)) return false
    }
    if (httpDuration) {
      if (httpDuration === 'lt100' ? p.duration >= 100 : p.duration < parseInt(httpDuration)) return false
    }
    return true
  })

  const filteredJobs = jobs.filter(p => {
    if (jobSearch && !p.path.toLowerCase().includes(jobSearch.toLowerCase())) return false
    if (jobStatus === 'failed' && p.status !== 500) return false
    if (jobStatus === 'completed' && p.status === 500) return false
    if (jobDuration) {
      if (jobDuration === 'lt100' ? p.duration >= 100 : p.duration < parseInt(jobDuration)) return false
    }
    return true
  })

  const filteredOutbound = outboundRequests.filter(req => {
    if (outboundSearch && !req.url.toLowerCase().includes(outboundSearch.toLowerCase())) return false
    if (outboundMethod && req.method !== outboundMethod) return false
    if (outboundStatus) {
      if (outboundStatus === 'error') {
        if (req.status !== 0) return false
      } else {
        const base = parseInt(outboundStatus)
        if (!(req.status >= base && req.status < base + 100)) return false
      }
    }
    return true
  })

  const httpFiltersActive = !!(httpSearch || httpMethod || httpStatus || httpDuration)
  const jobFiltersActive = !!(jobSearch || jobStatus || jobDuration)
  const outboundFiltersActive = !!(outboundSearch || outboundMethod || outboundStatus)

  return (
    <div class="container">
      <div class="header">
        <h1><span class="h1-emoji">🔍</span> Rails Profiler</h1>
        <p>Recent profiled requests and jobs</p>
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          <a href="#" class={tabClass('http')} onClick={e => { e.preventDefault(); handleSectionChange('http') }}>HTTP Requests</a>
          <a href="#" class={tabClass('jobs')} onClick={e => { e.preventDefault(); handleSectionChange('jobs') }}>Background Jobs</a>
          <a href="#" class={tabClass('outbound')} onClick={e => { e.preventDefault(); handleSectionChange('outbound') }}>Outbound HTTP</a>
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
              <>
                <div class="profiler-action-bar profiler-mb-3">
                  <div class="profiler-filter-group">
                    <input
                      type="text"
                      class="profiler-filter-input"
                      placeholder="Search path…"
                      value={httpSearch}
                      onInput={e => setHttpSearch((e.target as HTMLInputElement).value)}
                    />
                    <select class="profiler-filter-select" value={httpMethod} onChange={e => setHttpMethod((e.target as HTMLSelectElement).value)}>
                      <option value="">All Methods</option>
                      <option value="GET">GET</option>
                      <option value="POST">POST</option>
                      <option value="PUT">PUT</option>
                      <option value="PATCH">PATCH</option>
                      <option value="DELETE">DELETE</option>
                    </select>
                    <select class="profiler-filter-select" value={httpStatus} onChange={e => setHttpStatus((e.target as HTMLSelectElement).value)}>
                      <option value="">All Statuses</option>
                      <option value="200">2xx</option>
                      <option value="300">3xx</option>
                      <option value="400">4xx</option>
                      <option value="500">5xx</option>
                    </select>
                    <select class="profiler-filter-select" value={httpDuration} onChange={e => setHttpDuration((e.target as HTMLSelectElement).value)}>
                      <option value="">All Durations</option>
                      <option value="lt100">&lt;100ms</option>
                      <option value="100">≥100ms</option>
                      <option value="500">≥500ms</option>
                    </select>
                  </div>
                  <div class="profiler-filter-group">
                    {httpFiltersActive && (
                      <span class="profiler-filter-count">{filteredProfiles.length} / {profiles.length}</span>
                    )}
                    <button class={`btn-refresh${loadingHttp ? ' btn-refresh--spinning' : ''}`} onClick={refresh} disabled={loadingHttp} title="Refresh">↺</button>
                    <button class="btn btn-danger btn-sm" onClick={clearProfiles}>Clear All</button>
                  </div>
                </div>
                {filteredProfiles.length === 0 ? (
                  <div class="profiler-empty">
                    <div class="profiler-empty__title">No results match filters</div>
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
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredProfiles.map(p => (
                        <tr key={p.token}>
                          <td>{formatTime(p.started_at)}</td>
                          <td><span class={methodClass(p.method)}>{p.method}</span></td>
                          <td><a href={`${BASE}/profiles/${p.token}`}>{p.path}</a></td>
                          <td><span class={durationClass(p.duration)}>{p.duration.toFixed(2)} ms</span></td>
                          <td>{formatMemory(p.memory)}</td>
                          <td><span class={statusClass(p.status)}>{p.status}</span></td>
                          <td class="profiler-text--xs profiler-text--mono profiler-text--muted">
                            <button class="token-copy" onClick={() => copyToken(p.token)} title="Copy full token">
                              {copiedToken === p.token ? '✓' : p.token.substring(0, 8) + '…'}
                            </button>
                          </td>
                          <td><button class="btn-row-delete" onClick={() => deleteProfile(p.token)} title="Delete">×</button></td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </>
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
              <>
                <div class="profiler-action-bar profiler-mb-3">
                  <div class="profiler-filter-group">
                    <input
                      type="text"
                      class="profiler-filter-input"
                      placeholder="Search job class…"
                      value={jobSearch}
                      onInput={e => setJobSearch((e.target as HTMLInputElement).value)}
                    />
                    <select class="profiler-filter-select" value={jobStatus} onChange={e => setJobStatus((e.target as HTMLSelectElement).value)}>
                      <option value="">All Statuses</option>
                      <option value="completed">Completed</option>
                      <option value="failed">Failed</option>
                    </select>
                    <select class="profiler-filter-select" value={jobDuration} onChange={e => setJobDuration((e.target as HTMLSelectElement).value)}>
                      <option value="">All Durations</option>
                      <option value="lt100">&lt;100ms</option>
                      <option value="100">≥100ms</option>
                      <option value="500">≥500ms</option>
                    </select>
                  </div>
                  <div class="profiler-filter-group">
                    {jobFiltersActive && (
                      <span class="profiler-filter-count">{filteredJobs.length} / {jobs.length}</span>
                    )}
                    <button class={`btn-refresh${loadingJobs ? ' btn-refresh--spinning' : ''}`} onClick={refresh} disabled={loadingJobs} title="Refresh">↺</button>
                    <button class="btn btn-danger btn-sm" onClick={clearJobs}>Clear All</button>
                  </div>
                </div>
                {filteredJobs.length === 0 ? (
                  <div class="profiler-empty">
                    <div class="profiler-empty__title">No results match filters</div>
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
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {filteredJobs.map(p => {
                        const jobData = p.collectors_data?.job as any
                        const isFailed = p.status === 500
                        return (
                          <tr key={p.token}>
                            <td>{formatTime(p.started_at)}</td>
                            <td><a href={`${BASE}/profiles/${p.token}`}>{p.path}</a></td>
                            <td><span class="profiler-text--xs profiler-text--mono">{jobData?.queue || '-'}</span></td>
                            <td><span class={durationClass(p.duration)}>{p.duration.toFixed(2)} ms</span></td>
                            <td><span class={isFailed ? 'badge-error' : 'badge-success'}>{isFailed ? '✗ Failed' : '✓ Completed'}</span></td>
                            <td>{jobData?.executions ?? '-'}</td>
                            <td class="profiler-text--xs profiler-text--mono profiler-text--muted">
                              <button class="token-copy" onClick={() => copyToken(p.token)} title="Copy full token">
                                {copiedToken === p.token ? '✓' : p.token.substring(0, 8) + '…'}
                              </button>
                            </td>
                            <td><button class="btn-row-delete" onClick={() => deleteJob(p.token)} title="Delete">×</button></td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                )}
              </>
            )
          )}

          {section === 'outbound' && (
            loadingOutbound ? (
              <div class="profiler-empty"><div class="profiler-empty__title">Loading...</div></div>
            ) : outboundError ? (
              <div class="profiler-empty"><div class="profiler-empty__title">{outboundError}</div></div>
            ) : outboundRequests.length === 0 ? (
              <div class="profiler-empty">
                <div class="profiler-empty__title">No outbound HTTP requests found</div>
                <p class="profiler-empty__description">Make requests to external services to see outbound HTTP data</p>
              </div>
            ) : (
              <>
                <div class="profiler-action-bar profiler-mb-3">
                  <div class="profiler-filter-group">
                    <input
                      type="text"
                      class="profiler-filter-input"
                      placeholder="Search URL…"
                      value={outboundSearch}
                      onInput={e => setOutboundSearch((e.target as HTMLInputElement).value)}
                    />
                    <select class="profiler-filter-select" value={outboundMethod} onChange={e => setOutboundMethod((e.target as HTMLSelectElement).value)}>
                      <option value="">All Methods</option>
                      <option value="GET">GET</option>
                      <option value="POST">POST</option>
                      <option value="PUT">PUT</option>
                      <option value="PATCH">PATCH</option>
                      <option value="DELETE">DELETE</option>
                    </select>
                    <select class="profiler-filter-select" value={outboundStatus} onChange={e => setOutboundStatus((e.target as HTMLSelectElement).value)}>
                      <option value="">All Statuses</option>
                      <option value="200">2xx</option>
                      <option value="300">3xx</option>
                      <option value="400">4xx</option>
                      <option value="500">5xx</option>
                      <option value="error">Error</option>
                    </select>
                  </div>
                  <div class="profiler-filter-group">
                    {outboundFiltersActive && (
                      <span class="profiler-filter-count">{filteredOutbound.length} / {outboundRequests.length}</span>
                    )}
                    <button class={`btn-refresh${loadingOutbound ? ' btn-refresh--spinning' : ''}`} onClick={refresh} disabled={loadingOutbound} title="Refresh">↺</button>
                  </div>
                </div>
                <p class="profiler-text--xs profiler-text--muted profiler-mb-3">
                  {outboundRequests.length} outbound request{outboundRequests.length !== 1 ? 's' : ''} across all profiles. Click a request to expand headers and body.
                </p>
                {filteredOutbound.length === 0 ? (
                  <div class="profiler-empty">
                    <div class="profiler-empty__title">No results match filters</div>
                  </div>
                ) : (
                  filteredOutbound.map((req, i) => (
                    <div key={i} style="margin-bottom:4px">
                      <div class="profiler-text--xs profiler-text--muted" style="margin-bottom:2px">
                        {formatTime(req.profile_started_at)} · Profile: <a href={`${BASE}/profiles/${req.profile_token}`}>{req.profile_token.substring(0, 8)}…</a>
                      </div>
                      <HttpRequestDetail req={req} index={i} threshold={500} />
                    </div>
                  ))
                )}
              </>
            )
          )}
        </div>
      </div>
    </div>
  )
}
