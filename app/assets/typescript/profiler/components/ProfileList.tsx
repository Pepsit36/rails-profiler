import { useState, useEffect } from 'preact/hooks'
import { Profile, ProfilesResponse, HttpRequest } from '../dashboard/types'
import { HttpRequestDetail } from './dashboard/tabs/HttpTab'

const BASE = '/_profiler'

function TableSkeleton({ cols, rows = 6 }: { cols: Array<'xs' | 'sm' | 'md' | 'lg' | 'flex'>, rows?: number }) {
  return (
    <div>
      {Array.from({ length: rows }).map((_, i) => (
        <div key={i} class="profiler-skeleton__row">
          {cols.map((size, j) => (
            <div key={j} class={`profiler-skeleton__cell profiler-skeleton__cell--${size}`} />
          ))}
        </div>
      ))}
    </div>
  )
}

interface OutboundRequest extends HttpRequest {
  profile_token: string
  profile_started_at: string
}

type SortCol = 'date' | 'duration' | 'memory' | 'status' | 'queries' | null
type JobSortCol = 'date' | 'duration' | 'status' | null
type SortDir = 'asc' | 'desc'

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

const PRESETS = [
  { key: 'slow', label: 'Slow' },
  { key: 'many_queries', label: 'Many queries' },
  { key: 'errors', label: 'Errors' },
  { key: 'has_exception', label: 'Has exception' },
] as const

type PresetKey = typeof PRESETS[number]['key'] | ''

export function ProfileList() {
  const params = new URLSearchParams(window.location.search)

  const initialSection = (): 'http' | 'jobs' | 'outbound' => {
    const s = params.get('section')
    return (s === 'http' || s === 'jobs' || s === 'outbound') ? s : 'http'
  }

  const initialSort = (): { col: SortCol; dir: SortDir } => {
    const col = params.get('sort') as SortCol
    const dir = params.get('dir') as SortDir
    return {
      col: (col === 'date' || col === 'duration' || col === 'memory' || col === 'status' || col === 'queries') ? col : null,
      dir: dir === 'desc' ? 'desc' : 'asc'
    }
  }

  const [section, setSection] = useState<'http' | 'jobs' | 'outbound'>(initialSection)
  const [profiles, setProfiles] = useState<Profile[]>([])
  const [httpOffset, setHttpOffset] = useState(0)
  const [httpHasMore, setHttpHasMore] = useState(false)
  const [httpLoadingMore, setHttpLoadingMore] = useState(false)
  const [jobs, setJobs] = useState<Profile[]>([])
  const [jobOffset, setJobOffset] = useState(0)
  const [jobHasMore, setJobHasMore] = useState(false)
  const [jobLoadingMore, setJobLoadingMore] = useState(false)
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
  const [httpPreset, setHttpPreset] = useState<PresetKey>(() => {
    const p = params.get('preset') as PresetKey
    return PRESETS.some(pr => pr.key === p) ? p : ''
  })
  const [httpSort, setHttpSort] = useState<{ col: SortCol; dir: SortDir }>(initialSort)
  const [jobSort, setJobSort] = useState<{ col: JobSortCol; dir: SortDir }>({ col: null, dir: 'asc' })

  // Jobs filters
  const [jobSearch, setJobSearch] = useState('')
  const [jobStatus, setJobStatus] = useState('')
  const [jobDuration, setJobDuration] = useState('')
  // Outbound filters
  const [outboundSearch, setOutboundSearch] = useState('')
  const [outboundMethod, setOutboundMethod] = useState('')
  const [outboundStatus, setOutboundStatus] = useState('')

  useEffect(() => {
    fetch(`${BASE}/api/profiles?limit=50&offset=0`)
      .then(res => res.json())
      .then((data: ProfilesResponse) => {
        setProfiles(data.profiles)
        setHttpOffset(data.profiles.length)
        setHttpHasMore(data.has_more)
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

  // Sync sort + preset to URL
  useEffect(() => {
    const url = new URL(window.location.href)
    if (httpSort.col) {
      url.searchParams.set('sort', httpSort.col)
      url.searchParams.set('dir', httpSort.dir)
    } else {
      url.searchParams.delete('sort')
      url.searchParams.delete('dir')
    }
    if (httpPreset) {
      url.searchParams.set('preset', httpPreset)
    } else {
      url.searchParams.delete('preset')
    }
    history.replaceState(null, '', url.toString())
  }, [httpSort, httpPreset])

  const toggleHttpSort = (col: NonNullable<SortCol>) => {
    setHttpSort(prev =>
      prev.col === col
        ? { col, dir: prev.dir === 'asc' ? 'desc' : 'asc' }
        : { col, dir: 'asc' }
    )
  }

  const toggleJobSort = (col: NonNullable<JobSortCol>) => {
    setJobSort(prev =>
      prev.col === col
        ? { col, dir: prev.dir === 'asc' ? 'desc' : 'asc' }
        : { col, dir: 'asc' }
    )
  }

  const togglePreset = (key: typeof PRESETS[number]['key']) => {
    setHttpPreset(prev => prev === key ? '' : key)
  }

  const loadMoreHttp = () => {
    setHttpLoadingMore(true)
    fetch(`${BASE}/api/profiles?limit=50&offset=${httpOffset}`)
      .then(res => res.json())
      .then((data: ProfilesResponse) => {
        setProfiles(prev => [...prev, ...data.profiles])
        setHttpOffset(prev => prev + data.profiles.length)
        setHttpHasMore(data.has_more)
        setHttpLoadingMore(false)
      })
      .catch(() => setHttpLoadingMore(false))
  }

  const loadJobs = () => {
    if (jobsLoaded) return
    setLoadingJobs(true)
    fetch(`${BASE}/api/jobs?limit=50&offset=0`)
      .then(res => res.json())
      .then((data: ProfilesResponse) => {
        setJobs(data.profiles)
        setJobOffset(data.profiles.length)
        setJobHasMore(data.has_more)
        setLoadingJobs(false)
        setJobsLoaded(true)
      })
      .catch(() => {
        setJobsError('Failed to load job profiles')
        setLoadingJobs(false)
        setJobsLoaded(true)
      })
  }

  const loadMoreJobs = () => {
    setJobLoadingMore(true)
    fetch(`${BASE}/api/jobs?limit=50&offset=${jobOffset}`)
      .then(res => res.json())
      .then((data: ProfilesResponse) => {
        setJobs(prev => [...prev, ...data.profiles])
        setJobOffset(prev => prev + data.profiles.length)
        setJobHasMore(data.has_more)
        setJobLoadingMore(false)
      })
      .catch(() => setJobLoadingMore(false))
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
    setHttpPreset(''); setHttpSort({ col: null, dir: 'asc' })
    setJobSearch(''); setJobStatus(''); setJobDuration(''); setJobSort({ col: null, dir: 'asc' })
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
      fetch(`${BASE}/api/profiles?limit=50&offset=0`)
        .then(res => res.json())
        .then((data: ProfilesResponse) => {
          setProfiles(data.profiles)
          setHttpOffset(data.profiles.length)
          setHttpHasMore(data.has_more)
          setLoadingHttp(false)
        })
        .catch(() => { setError('Failed to load profiles'); setLoadingHttp(false) })
    } else if (section === 'jobs') {
      setLoadingJobs(true)
      fetch(`${BASE}/api/jobs?limit=50&offset=0`)
        .then(res => res.json())
        .then((data: ProfilesResponse) => {
          setJobs(data.profiles)
          setJobOffset(data.profiles.length)
          setJobHasMore(data.has_more)
          setLoadingJobs(false)
        })
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
    // Quick filter presets
    if (httpPreset === 'slow' && p.duration < 500) return false
    if (httpPreset === 'many_queries' && (p.collectors_data?.database?.total_queries ?? 0) <= 20) return false
    if (httpPreset === 'errors' && p.status < 500) return false
    if (httpPreset === 'has_exception' && !p.collectors_data?.exception) return false
    return true
  })

  const sortedProfiles = httpSort.col
    ? [...filteredProfiles].sort((a, b) => {
        if (httpSort.col === 'date') {
          const diff = new Date(a.started_at).getTime() - new Date(b.started_at).getTime()
          return httpSort.dir === 'asc' ? diff : -diff
        }
        let av: number, bv: number
        switch (httpSort.col) {
          case 'duration': av = a.duration; bv = b.duration; break
          case 'memory': av = a.memory ?? 0; bv = b.memory ?? 0; break
          case 'status': av = a.status; bv = b.status; break
          case 'queries': av = a.collectors_data?.database?.total_queries ?? 0; bv = b.collectors_data?.database?.total_queries ?? 0; break
          default: return 0
        }
        return httpSort.dir === 'asc' ? av - bv : bv - av
      })
    : filteredProfiles

  const filteredJobs = jobs.filter(p => {
    if (jobSearch && !p.path.toLowerCase().includes(jobSearch.toLowerCase())) return false
    if (jobStatus === 'failed' && p.status !== 500) return false
    if (jobStatus === 'completed' && p.status === 500) return false
    if (jobDuration) {
      if (jobDuration === 'lt100' ? p.duration >= 100 : p.duration < parseInt(jobDuration)) return false
    }
    return true
  })

  const sortedJobs = jobSort.col
    ? [...filteredJobs].sort((a, b) => {
        if (jobSort.col === 'date') {
          const diff = new Date(a.started_at).getTime() - new Date(b.started_at).getTime()
          return jobSort.dir === 'asc' ? diff : -diff
        }
        let av: number, bv: number
        switch (jobSort.col) {
          case 'duration': av = a.duration; bv = b.duration; break
          case 'status': av = a.status; bv = b.status; break
          default: return 0
        }
        return jobSort.dir === 'asc' ? av - bv : bv - av
      })
    : filteredJobs

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

  const httpFiltersActive = !!(httpSearch || httpMethod || httpStatus || httpDuration || httpPreset)
  const jobFiltersActive = !!(jobSearch || jobStatus || jobDuration)
  const outboundFiltersActive = !!(outboundSearch || outboundMethod || outboundStatus)

  const sortIcon = (activeCol: string | null, dir: SortDir, col: string) => {
    if (activeCol !== col) return <span class="sort-icon sort-icon--idle">⇅</span>
    return <span class="sort-icon sort-icon--active">{dir === 'asc' ? '▲' : '▼'}</span>
  }

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
              <TableSkeleton cols={['sm', 'xs', 'flex', 'sm', 'sm', 'sm', 'xs', 'sm']} />
            ) : error ? (
              <div class="profiler-empty"><div class="profiler-empty__title">{error}</div></div>
            ) : profiles.length === 0 ? (
              <div class="profiler-empty">
                <div class="profiler-empty__title">No profiles found</div>
                <p class="profiler-empty__description">Make some requests to your application to see profiling data</p>
              </div>
            ) : (
              <>
                <div class="profiler-action-bar profiler-mb-2">
                  <div class="profiler-filter-group">
                    {PRESETS.map(preset => (
                      <button
                        key={preset.key}
                        class={`profiler-preset-btn${httpPreset === preset.key ? ' profiler-preset-btn--active' : ''}`}
                        onClick={() => togglePreset(preset.key)}
                      >
                        {preset.label}
                      </button>
                    ))}
                  </div>
                </div>
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
                        <th class={`sortable${httpSort.col === 'date' ? ' sortable--active' : ''}`} onClick={() => toggleHttpSort('date')}>
                          Time {sortIcon(httpSort.col, httpSort.dir, 'date')}
                        </th>
                        <th>Method</th>
                        <th>Path</th>
                        <th class={`sortable${httpSort.col === 'duration' ? ' sortable--active' : ''}`} onClick={() => toggleHttpSort('duration')}>
                          Duration {sortIcon(httpSort.col, httpSort.dir, 'duration')}
                        </th>
                        <th class={`sortable${httpSort.col === 'queries' ? ' sortable--active' : ''}`} onClick={() => toggleHttpSort('queries')}>
                          Queries {sortIcon(httpSort.col, httpSort.dir, 'queries')}
                        </th>
                        <th class={`sortable${httpSort.col === 'memory' ? ' sortable--active' : ''}`} onClick={() => toggleHttpSort('memory')}>
                          Memory {sortIcon(httpSort.col, httpSort.dir, 'memory')}
                        </th>
                        <th class={`sortable${httpSort.col === 'status' ? ' sortable--active' : ''}`} onClick={() => toggleHttpSort('status')}>
                          Status {sortIcon(httpSort.col, httpSort.dir, 'status')}
                        </th>
                        <th>Token</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {sortedProfiles.map(p => (
                        <tr key={p.token}>
                          <td>{formatTime(p.started_at)}</td>
                          <td><span class={methodClass(p.method)}>{p.method}</span></td>
                          <td><a href={`${BASE}/profiles/${p.token}`}>{p.path}</a></td>
                          <td><span class={durationClass(p.duration)}>{p.duration.toFixed(2)} ms</span></td>
                          <td>{p.collectors_data?.database?.total_queries ?? '—'}</td>
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
                {httpHasMore && !httpFiltersActive && (
                  <div class="profiler-load-more">
                    <button class="btn btn-secondary" onClick={loadMoreHttp} disabled={httpLoadingMore}>
                      {httpLoadingMore ? 'Loading…' : 'Load more'}
                    </button>
                  </div>
                )}
              </>
            )
          )}

          {section === 'jobs' && (
            loadingJobs ? (
              <TableSkeleton cols={['sm', 'flex', 'md', 'sm', 'xs', 'xs', 'sm']} />
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
                        <th class={`sortable${jobSort.col === 'date' ? ' sortable--active' : ''}`} onClick={() => toggleJobSort('date')}>
                          Time {sortIcon(jobSort.col, jobSort.dir, 'date')}
                        </th>
                        <th>Job Class</th>
                        <th>Queue</th>
                        <th class={`sortable${jobSort.col === 'duration' ? ' sortable--active' : ''}`} onClick={() => toggleJobSort('duration')}>
                          Duration {sortIcon(jobSort.col, jobSort.dir, 'duration')}
                        </th>
                        <th class={`sortable${jobSort.col === 'status' ? ' sortable--active' : ''}`} onClick={() => toggleJobSort('status')}>
                          Status {sortIcon(jobSort.col, jobSort.dir, 'status')}
                        </th>
                        <th>Executions</th>
                        <th>Token</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {sortedJobs.map(p => {
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
                {jobHasMore && !jobFiltersActive && (
                  <div class="profiler-load-more">
                    <button class="btn btn-secondary" onClick={loadMoreJobs} disabled={jobLoadingMore}>
                      {jobLoadingMore ? 'Loading…' : 'Load more'}
                    </button>
                  </div>
                )}
              </>
            )
          )}

          {section === 'outbound' && (
            loadingOutbound ? (
              <TableSkeleton cols={['sm', 'xs', 'flex', 'sm', 'xs']} rows={4} />
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
