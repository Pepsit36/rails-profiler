import { useState, useEffect } from 'preact/hooks'
import type { InfiniteData } from '@tanstack/react-query'
import {
  useListProfilesInfinite, useListJobsInfinite, useListConsolesInfinite, useListTestsInfinite,
  listProfiles, listJobs, listConsoles, listTests,
  useListOutboundRequests, useGetEnvVars,
  useDeleteProfile, useClearProfiles,
  useDeleteJob, useClearJobs,
  useDeleteConsole, useClearConsoles,
  useDeleteTest, useClearTests,
} from '../generated/api'
import type { Profile, HttpRequest, ProfilesResponse } from '../dashboard/types'
import { getGemVersion } from '../dashboard/utils'
import { HttpRequestDetail } from './dashboard/tabs/HttpTab'
import { EnvTab } from './dashboard/tabs/EnvTab'
import { TestRunnerContent } from './test-runner/TestRunnerContent'

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
type ConsoleSortCol = 'date' | 'duration' | 'status' | null
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
  const currentVersion = getGemVersion()
  const params = new URLSearchParams(window.location.search)

  const initialSection = (): 'http' | 'jobs' | 'console' | 'tests' | 'runner' | 'outbound' | 'env' => {
    const s = params.get('section')
    return (s === 'http' || s === 'jobs' || s === 'console' || s === 'tests' || s === 'runner' || s === 'outbound' || s === 'env') ? s : 'http'
  }

  const initialSort = (): { col: SortCol; dir: SortDir } => {
    const col = params.get('sort') as SortCol
    const dir = params.get('dir') as SortDir
    return {
      col: (col === 'date' || col === 'duration' || col === 'memory' || col === 'status' || col === 'queries') ? col : null,
      dir: dir === 'desc' ? 'desc' : 'asc'
    }
  }

  const [section, setSection] = useState<'http' | 'jobs' | 'console' | 'tests' | 'runner' | 'outbound' | 'env'>(initialSection)

  const infiniteOpts = (
    key: string,
    fetchFn: (offset: number, signal?: AbortSignal) => Promise<any>
  ): any => ({
    query: {
      enabled: section === key,
      queryFn: ({ pageParam = 0, signal }: any) => fetchFn(pageParam as number, signal),
      getNextPageParam: (lastPage: { has_more: boolean; offset: number; limit: number }) =>
        lastPage.has_more ? lastPage.offset + lastPage.limit : undefined,
      initialPageParam: 0,
      refetchOnWindowFocus: false,
    }
  })

  const httpQuery     = useListProfilesInfinite({ limit: 50 }, infiniteOpts('http',    (offset, signal) => listProfiles({ limit: 50, offset }, signal)))
  const jobsQuery     = useListJobsInfinite({ limit: 50 },     infiniteOpts('jobs',    (offset, signal) => listJobs({ limit: 50, offset }, signal)))
  const consolesQuery = useListConsolesInfinite({ limit: 50 }, infiniteOpts('console', (offset, signal) => listConsoles({ limit: 50, offset }, signal)))
  const testsQuery    = useListTestsInfinite({ limit: 50 },    infiniteOpts('tests',   (offset, signal) => listTests({ limit: 50, offset }, signal)))
  const outboundQuery = useListOutboundRequests({ query: { enabled: section === 'outbound', refetchOnWindowFocus: false } } as any)
  const envQuery     = useGetEnvVars({ query: { enabled: section === 'env', refetchOnWindowFocus: false } } as any)

  const { mutateAsync: deleteProfileMutation } = useDeleteProfile()
  const { mutateAsync: clearProfilesMutation } = useClearProfiles()
  const { mutateAsync: deleteJobMutation }     = useDeleteJob()
  const { mutateAsync: clearJobsMutation }     = useClearJobs()
  const { mutateAsync: deleteConsoleMutation } = useDeleteConsole()
  const { mutateAsync: clearConsolesMutation } = useClearConsoles()
  const { mutateAsync: deleteTestMutation }    = useDeleteTest()
  const { mutateAsync: clearTestsMutation }    = useClearTests()

  const profiles        = (httpQuery.data as InfiniteData<ProfilesResponse> | undefined)?.pages.flatMap(p => p.profiles) ?? []
  const jobs            = (jobsQuery.data as InfiniteData<ProfilesResponse> | undefined)?.pages.flatMap(p => p.profiles) ?? []
  const consoles        = (consolesQuery.data as InfiniteData<ProfilesResponse> | undefined)?.pages.flatMap(p => p.profiles) ?? []
  const tests           = (testsQuery.data as InfiniteData<ProfilesResponse> | undefined)?.pages.flatMap(p => p.profiles) ?? []
  const outboundRequests = (outboundQuery.data ?? []) as OutboundRequest[]
  const envData         = envQuery.data

  const loadingHttp    = httpQuery.isLoading
  const loadingJobs    = jobsQuery.isLoading
  const loadingConsole = consolesQuery.isLoading
  const loadingTests   = testsQuery.isLoading
  const loadingOutbound = outboundQuery.isLoading
  const loadingEnv     = envQuery.isLoading

  const error        = (httpQuery.error as Error | null)?.message ?? null
  const jobsError    = (jobsQuery.error as Error | null)?.message ?? null
  const consoleError = (consolesQuery.error as Error | null)?.message ?? null
  const testsError   = (testsQuery.error as Error | null)?.message ?? null
  const outboundError = (outboundQuery.error as Error | null)?.message ?? null
  const envError     = (envQuery.error as Error | null)?.message ?? null

  const httpHasMore    = !!httpQuery.hasNextPage
  const jobHasMore     = !!jobsQuery.hasNextPage
  const consoleHasMore = !!consolesQuery.hasNextPage
  const testHasMore    = !!testsQuery.hasNextPage

  const httpLoadingMore    = httpQuery.isFetchingNextPage
  const jobLoadingMore     = jobsQuery.isFetchingNextPage
  const consoleLoadingMore = consolesQuery.isFetchingNextPage
  const testLoadingMore    = testsQuery.isFetchingNextPage
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
  const [consoleSort, setConsoleSort] = useState<{ col: ConsoleSortCol; dir: SortDir }>({ col: null, dir: 'asc' })

  // Jobs filters
  const [jobSearch, setJobSearch] = useState('')
  const [jobStatus, setJobStatus] = useState('')
  const [jobDuration, setJobDuration] = useState('')
  // Console filters
  const [consoleSearch, setConsoleSearch] = useState('')
  const [consoleStatus, setConsoleStatus] = useState('')
  // Tests filters
  const [testSearch, setTestSearch] = useState('')
  const [testStatus, setTestStatus] = useState('')
  const [testSort, setTestSort] = useState<{ col: JobSortCol; dir: SortDir }>({ col: null, dir: 'asc' })
  // Outbound filters
  const [outboundSearch, setOutboundSearch] = useState('')
  const [outboundMethod, setOutboundMethod] = useState('')
  const [outboundStatus, setOutboundStatus] = useState('')

  // Queries auto-fetch when section matches their `enabled` condition

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

  const loadMoreHttp    = () => httpQuery.fetchNextPage()
  const loadMoreJobs    = () => jobsQuery.fetchNextPage()
  const loadMoreConsole = () => consolesQuery.fetchNextPage()
  const loadMoreTests   = () => testsQuery.fetchNextPage()

  const refetchSection = (s: typeof section) => {
    if (s === 'http')     httpQuery.refetch()
    else if (s === 'jobs')     jobsQuery.refetch()
    else if (s === 'console')  consolesQuery.refetch()
    else if (s === 'tests')    testsQuery.refetch()
    else if (s === 'outbound') outboundQuery.refetch()
    else if (s === 'env')      envQuery.refetch()
  }

  const handleSectionChange = (s: 'http' | 'jobs' | 'console' | 'tests' | 'runner' | 'outbound' | 'env') => {
    if (s === section) {
      refetchSection(s)
      return
    }
    setSection(s)
    const url = new URL(window.location.href)
    url.searchParams.set('section', s)
    history.pushState(null, '', url.toString())
    // Reset all filters
    setHttpSearch(''); setHttpMethod(''); setHttpStatus(''); setHttpDuration('')
    setHttpPreset(''); setHttpSort({ col: null, dir: 'asc' })
    setJobSearch(''); setJobStatus(''); setJobDuration(''); setJobSort({ col: null, dir: 'asc' })
    setConsoleSearch(''); setConsoleStatus(''); setConsoleSort({ col: null, dir: 'asc' })
    setTestSearch(''); setTestStatus(''); setTestSort({ col: null, dir: 'asc' })
    setOutboundSearch(''); setOutboundMethod(''); setOutboundStatus('')
  }

  const copyToken = (token: string) => {
    navigator.clipboard.writeText(token).then(() => {
      setCopiedToken(token)
      setTimeout(() => setCopiedToken(null), 1500)
    })
  }

  const deleteProfile = (token: string) =>
    deleteProfileMutation({ id: token }).then(() => httpQuery.refetch())

  const deleteJob = (token: string) =>
    deleteJobMutation({ id: token }).then(() => jobsQuery.refetch())

  const deleteConsole = (token: string) =>
    deleteConsoleMutation({ id: token }).then(() => consolesQuery.refetch())

  const deleteTest = (token: string) =>
    deleteTestMutation({ id: token }).then(() => testsQuery.refetch())

  const clearProfiles = () => {
    if (!window.confirm('Delete all HTTP profiles?')) return
    clearProfilesMutation().then(() => httpQuery.refetch())
  }

  const clearJobs = () => {
    if (!window.confirm('Delete all job profiles?')) return
    clearJobsMutation().then(() => jobsQuery.refetch())
  }

  const clearConsole = () => {
    if (!window.confirm('Delete all console profiles?')) return
    clearConsolesMutation().then(() => consolesQuery.refetch())
  }

  const clearTests = () => {
    if (!window.confirm('Delete all test profiles?')) return
    clearTestsMutation().then(() => testsQuery.refetch())
  }

  const clearAll = () => {
    if (!window.confirm('Delete all HTTP, job and console profiles?')) return
    Promise.all([
      clearProfilesMutation(),
      clearJobsMutation(),
      clearConsolesMutation(),
    ]).then(() => {
      httpQuery.refetch()
      jobsQuery.refetch()
      consolesQuery.refetch()
    })
  }

  const refresh = () => refetchSection(section)

  const toggleConsoleSort = (col: NonNullable<ConsoleSortCol>) => {
    setConsoleSort(prev =>
      prev.col === col
        ? { col, dir: prev.dir === 'asc' ? 'desc' : 'asc' }
        : { col, dir: 'asc' }
    )
  }

  const tabClass = (s: 'http' | 'jobs' | 'console' | 'tests' | 'runner' | 'outbound' | 'env') => `tab${section === s ? ' active' : ''}`

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

  const filteredConsoles = consoles.filter(p => {
    if (consoleSearch && !p.path.toLowerCase().includes(consoleSearch.toLowerCase())) return false
    if (consoleStatus === 'error' && p.status !== 500) return false
    if (consoleStatus === 'ok' && p.status === 500) return false
    return true
  })

  const sortedConsoles = consoleSort.col
    ? [...filteredConsoles].sort((a, b) => {
        if (consoleSort.col === 'date') {
          const diff = new Date(a.started_at).getTime() - new Date(b.started_at).getTime()
          return consoleSort.dir === 'asc' ? diff : -diff
        }
        let av: number, bv: number
        switch (consoleSort.col) {
          case 'duration': av = a.duration; bv = b.duration; break
          case 'status': av = a.status; bv = b.status; break
          default: return 0
        }
        return consoleSort.dir === 'asc' ? av - bv : bv - av
      })
    : filteredConsoles

  const filteredTests = tests.filter(p => {
    if (testSearch) {
      const testData = p.collectors_data?.test as any
      const name = (testData?.test_name || p.path).toLowerCase()
      if (!name.includes(testSearch.toLowerCase())) return false
    }
    if (testStatus === 'failed' && p.status !== 500) return false
    if (testStatus === 'passed' && p.status === 500) return false
    if (testStatus === 'pending') {
      const testData = p.collectors_data?.test as any
      if (testData?.status !== 'pending') return false
    }
    return true
  })

  const sortedTests = testSort.col
    ? [...filteredTests].sort((a, b) => {
        let av: number, bv: number
        if (testSort.col === 'date') {
          const diff = new Date(a.started_at).getTime() - new Date(b.started_at).getTime()
          return testSort.dir === 'asc' ? diff : -diff
        }
        switch (testSort.col) {
          case 'duration': av = a.duration; bv = b.duration; break
          case 'status': av = a.status; bv = b.status; break
          default: return 0
        }
        return testSort.dir === 'asc' ? av - bv : bv - av
      })
    : filteredTests

  const httpFiltersActive = !!(httpSearch || httpMethod || httpStatus || httpDuration || httpPreset)
  const jobFiltersActive = !!(jobSearch || jobStatus || jobDuration)
  const consoleFiltersActive = !!(consoleSearch || consoleStatus)
  const testFiltersActive = !!(testSearch || testStatus)
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
        {currentVersion && <span class="profiler-version-badge">v{currentVersion}</span>}
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          <a href="#" class={tabClass('http')} onClick={e => { e.preventDefault(); handleSectionChange('http') }}>HTTP Requests</a>
          <a href="#" class={tabClass('jobs')} onClick={e => { e.preventDefault(); handleSectionChange('jobs') }}>Background Jobs</a>
          <a href="#" class={tabClass('console')} onClick={e => { e.preventDefault(); handleSectionChange('console') }}>Console</a>
          <a href="#" class={tabClass('tests')} onClick={e => { e.preventDefault(); handleSectionChange('tests') }}>Tests</a>
          <div style="flex: 1" />
          <a href="#" class={tabClass('runner')} onClick={e => { e.preventDefault(); handleSectionChange('runner') }}>Test Runner</a>
          <a href="#" class={tabClass('outbound')} onClick={e => { e.preventDefault(); handleSectionChange('outbound') }}>Outbound HTTP</a>
          <a href="#" class={tabClass('env')} onClick={e => { e.preventDefault(); handleSectionChange('env') }}>Env</a>
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
                    <button class="btn btn-danger btn-sm" onClick={clearProfiles} title="Delete HTTP profiles">Clear</button>
                    <button class="btn btn-danger btn-sm" onClick={clearAll} title="Delete all HTTP and job profiles">Clear All</button>
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
                          <td>
                            <a href={`${BASE}/profiles/${p.token}`}>{p.path}</a>
                            {p.gem_version && p.gem_version !== currentVersion && (
                              <span class="profiler-version-warn" title={`Capturé avec v${p.gem_version} (actuel : v${currentVersion})`}>⚠️</span>
                            )}
                          </td>
                          <td><span class={durationClass(p.duration)}>{p.duration.toFixed(2)} ms</span></td>
                          <td>{p.collectors_data?.database?.total_queries ?? '—'}</td>
                          <td>{formatMemory(p.memory ?? undefined)}</td>
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
                    <button class="btn btn-danger btn-sm" onClick={clearJobs} title="Delete job profiles">Clear</button>
                    <button class="btn btn-danger btn-sm" onClick={clearAll} title="Delete all HTTP and job profiles">Clear All</button>
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
                            <td>
                              <a href={`${BASE}/profiles/${p.token}`}>{p.path}</a>
                              {p.gem_version && p.gem_version !== currentVersion && (
                                <span class="profiler-version-warn" title={`Capturé avec v${p.gem_version} (actuel : v${currentVersion})`}>⚠️</span>
                              )}
                            </td>
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

          {section === 'console' && (
            loadingConsole ? (
              <TableSkeleton cols={['sm', 'flex', 'sm', 'sm', 'xs', 'sm']} />
            ) : consoleError ? (
              <div class="profiler-empty"><div class="profiler-empty__title">{consoleError}</div></div>
            ) : consoles.length === 0 ? (
              <div class="profiler-empty">
                <div class="profiler-empty__title">No console profiles found</div>
                <p class="profiler-empty__description">Run expressions in <code>rails console</code> to see profiling data</p>
              </div>
            ) : (
              <>
                <div class="profiler-action-bar profiler-mb-3">
                  <div class="profiler-filter-group">
                    <input
                      type="text"
                      class="profiler-filter-input"
                      placeholder="Search expression…"
                      value={consoleSearch}
                      onInput={e => setConsoleSearch((e.target as HTMLInputElement).value)}
                    />
                    <select class="profiler-filter-select" value={consoleStatus} onChange={e => setConsoleStatus((e.target as HTMLSelectElement).value)}>
                      <option value="">All Statuses</option>
                      <option value="ok">OK</option>
                      <option value="error">Error</option>
                    </select>
                  </div>
                  <div class="profiler-filter-group">
                    {consoleFiltersActive && (
                      <span class="profiler-filter-count">{filteredConsoles.length} / {consoles.length}</span>
                    )}
                    <button class={`btn-refresh${loadingConsole ? ' btn-refresh--spinning' : ''}`} onClick={refresh} disabled={loadingConsole} title="Refresh">↺</button>
                    <button class="btn btn-danger btn-sm" onClick={clearConsole} title="Delete console profiles">Clear</button>
                    <button class="btn btn-danger btn-sm" onClick={clearAll} title="Delete all profiles">Clear All</button>
                  </div>
                </div>
                {filteredConsoles.length === 0 ? (
                  <div class="profiler-empty">
                    <div class="profiler-empty__title">No results match filters</div>
                  </div>
                ) : (
                  <table>
                    <thead>
                      <tr>
                        <th class={`sortable${consoleSort.col === 'date' ? ' sortable--active' : ''}`} onClick={() => toggleConsoleSort('date')}>
                          Time {sortIcon(consoleSort.col, consoleSort.dir, 'date')}
                        </th>
                        <th>Expression</th>
                        <th class={`sortable${consoleSort.col === 'duration' ? ' sortable--active' : ''}`} onClick={() => toggleConsoleSort('duration')}>
                          Duration {sortIcon(consoleSort.col, consoleSort.dir, 'duration')}
                        </th>
                        <th>SQL</th>
                        <th class={`sortable${consoleSort.col === 'status' ? ' sortable--active' : ''}`} onClick={() => toggleConsoleSort('status')}>
                          Status {sortIcon(consoleSort.col, consoleSort.dir, 'status')}
                        </th>
                        <th>Token</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {sortedConsoles.map(p => {
                        const isError = p.status === 500
                        return (
                          <tr key={p.token}>
                            <td>{formatTime(p.started_at)}</td>
                            <td>
                              <a href={`${BASE}/profiles/${p.token}`} class="profiler-text--mono" style="font-size:0.85em;">
                                {p.path.length > 60 ? p.path.slice(0, 60) + '…' : p.path}
                              </a>
                              {p.gem_version && p.gem_version !== currentVersion && (
                                <span class="profiler-version-warn" title={`Capturé avec v${p.gem_version} (actuel : v${currentVersion})`}>⚠️</span>
                              )}
                            </td>
                            <td><span class={durationClass(p.duration)}>{p.duration.toFixed(2)} ms</span></td>
                            <td>{(p.collectors_data?.database as any)?.total_queries ?? '—'}</td>
                            <td><span class={isError ? 'badge-error' : 'badge-success'}>{isError ? '✗ Error' : '✓ OK'}</span></td>
                            <td class="profiler-text--xs profiler-text--mono profiler-text--muted">
                              <button class="token-copy" onClick={() => copyToken(p.token)} title="Copy full token">
                                {copiedToken === p.token ? '✓' : p.token.substring(0, 8) + '…'}
                              </button>
                            </td>
                            <td><button class="btn-row-delete" onClick={() => deleteConsole(p.token)} title="Delete">×</button></td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                )}
                {consoleHasMore && !consoleFiltersActive && (
                  <div class="profiler-load-more">
                    <button class="btn btn-secondary" onClick={loadMoreConsole} disabled={consoleLoadingMore}>
                      {consoleLoadingMore ? 'Loading…' : 'Load more'}
                    </button>
                  </div>
                )}
              </>
            )
          )}

          {section === 'tests' && (
            loadingTests ? (
              <TableSkeleton cols={['sm', 'flex', 'md', 'sm', 'xs', 'sm']} />
            ) : testsError ? (
              <div class="profiler-empty"><div class="profiler-empty__title">{testsError}</div></div>
            ) : tests.length === 0 ? (
              <div class="profiler-empty">
                <div class="profiler-empty__title">No test profiles found</div>
                <p class="profiler-empty__description">
                  Add <code>Profiler::TestHelpers::RSpecSupport.install(config)</code> to your spec_helper.rb and run your tests.
                  Or use the <a href="#" style="color:var(--profiler-accent,#06b6d4)" onClick={e => { e.preventDefault(); handleSectionChange('runner') }}>Test Runner</a> tab to run tests from here.
                </p>
              </div>
            ) : (
              <>
                <div class="profiler-action-bar profiler-mb-3">
                  <div class="profiler-filter-group">
                    <input
                      type="text"
                      class="profiler-filter-input"
                      placeholder="Search test name…"
                      value={testSearch}
                      onInput={e => setTestSearch((e.target as HTMLInputElement).value)}
                    />
                    <select class="profiler-filter-select" value={testStatus} onChange={e => setTestStatus((e.target as HTMLSelectElement).value)}>
                      <option value="">All Statuses</option>
                      <option value="passed">Passed</option>
                      <option value="failed">Failed</option>
                      <option value="pending">Pending</option>
                    </select>
                  </div>
                  <div class="profiler-filter-group">
                    {testFiltersActive && (
                      <span class="profiler-filter-count">{filteredTests.length} / {tests.length}</span>
                    )}
                    <button class={`btn-refresh${loadingTests ? ' btn-refresh--spinning' : ''}`} onClick={refresh} disabled={loadingTests} title="Refresh">↺</button>
                    <button class="btn btn-danger btn-sm" onClick={clearTests} title="Delete test profiles">Clear All</button>
                  </div>
                </div>
                {filteredTests.length === 0 ? (
                  <div class="profiler-empty">
                    <div class="profiler-empty__title">No results match filters</div>
                  </div>
                ) : (
                  <table>
                    <thead>
                      <tr>
                        <th class={`sortable${testSort.col === 'date' ? ' sortable--active' : ''}`} onClick={() => setTestSort(prev => ({ col: 'date', dir: prev.col === 'date' && prev.dir === 'asc' ? 'desc' : 'asc' }))}>
                          Time {sortIcon(testSort.col, testSort.dir, 'date')}
                        </th>
                        <th>Test Name</th>
                        <th>File</th>
                        <th class={`sortable${testSort.col === 'duration' ? ' sortable--active' : ''}`} onClick={() => setTestSort(prev => ({ col: 'duration', dir: prev.col === 'duration' && prev.dir === 'asc' ? 'desc' : 'asc' }))}>
                          Duration {sortIcon(testSort.col, testSort.dir, 'duration')}
                        </th>
                        <th>Queries</th>
                        <th class={`sortable${testSort.col === 'status' ? ' sortable--active' : ''}`} onClick={() => setTestSort(prev => ({ col: 'status', dir: prev.col === 'status' && prev.dir === 'asc' ? 'desc' : 'asc' }))}>
                          Status {sortIcon(testSort.col, testSort.dir, 'status')}
                        </th>
                        <th>Token</th>
                        <th></th>
                      </tr>
                    </thead>
                    <tbody>
                      {sortedTests.map(p => {
                        const testData = p.collectors_data?.test as any
                        const isFailed = p.status === 500
                        const status = testData?.status || (isFailed ? 'failed' : 'passed')
                        return (
                          <tr key={p.token}>
                            <td>{formatTime(p.started_at)}</td>
                            <td style="max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap">
                              <a href={`${BASE}/profiles/${p.token}`} title={testData?.test_name || p.path}>
                                {testData?.test_name || p.path}
                              </a>
                            </td>
                            <td class="profiler-text--xs profiler-text--mono profiler-text--muted">{testData?.test_file || '-'}</td>
                            <td><span class={durationClass(p.duration)}>{p.duration.toFixed(2)} ms</span></td>
                            <td>{p.collectors_data?.database?.total_queries ?? '—'}</td>
                            <td>
                              <span class={status === 'failed' ? 'badge-error' : status === 'pending' ? 'badge-warning' : 'badge-success'}>
                                {status === 'failed' ? '✗ Failed' : status === 'pending' ? '⏸ Pending' : '✓ Passed'}
                              </span>
                            </td>
                            <td class="profiler-text--xs profiler-text--mono profiler-text--muted">
                              <button class="token-copy" onClick={() => copyToken(p.token)} title="Copy full token">
                                {copiedToken === p.token ? '✓' : p.token.substring(0, 8) + '…'}
                              </button>
                            </td>
                            <td><button class="btn-row-delete" onClick={() => deleteTest(p.token)} title="Delete">×</button></td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                )}
                {testHasMore && !testFiltersActive && (
                  <div class="profiler-load-more">
                    <button class="btn btn-secondary" onClick={loadMoreTests} disabled={testLoadingMore}>
                      {testLoadingMore ? 'Loading…' : 'Load more'}
                    </button>
                  </div>
                )}
              </>
            )
          )}

          {section === 'runner' && (
            <TestRunnerContent />
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
          {section === 'env' && (
            loadingEnv ? (
              <TableSkeleton cols={['sm', 'flex', 'sm', 'sm']} rows={8} />
            ) : envError ? (
              <div class="profiler-empty"><div class="profiler-empty__title">{envError}</div></div>
            ) : (
              <EnvTab envData={envData} />
            )
          )}
        </div>
      </div>
    </div>
  )
}
