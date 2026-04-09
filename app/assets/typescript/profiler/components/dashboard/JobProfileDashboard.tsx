import { useState } from 'preact/hooks'
import { Profile } from '../../dashboard/types'
import { JobTab } from './tabs/JobTab'
import { DatabaseTab } from './tabs/DatabaseTab'
import { CacheTab } from './tabs/CacheTab'
import { HttpTab } from './tabs/HttpTab'
import { JobsTab } from './tabs/JobsTab'

type JobTabKey = 'job' | 'database' | 'cache' | 'http' | 'jobs'

interface Props {
  profile: Profile
  initialTab: string
  embedded: boolean
}

export function JobProfileDashboard({ profile, initialTab, embedded }: Props) {
  const validTabs: JobTabKey[] = ['job', 'database', 'cache', 'http', 'jobs']
  const defaultTab: JobTabKey = validTabs.includes(initialTab as JobTabKey) ? (initialTab as JobTabKey) : 'job'
  const [activeTab, setActiveTab] = useState<JobTabKey>(defaultTab)

  const cd = profile.collectors_data || {}
  const hasHttp = (cd['http'] as any)?.total_requests > 0
  const hasJobs = (profile.child_jobs?.length ?? 0) > 0
  const jobData = cd['job'] as any
  const isFailed = jobData?.status === 'failed'
  const parent = profile.parent_profile

  const handleTabClick = (tab: JobTabKey) => (e: MouseEvent) => {
    e.preventDefault()
    setActiveTab(tab)
    const url = new URL(window.location.href)
    url.searchParams.set('tab', tab)
    history.pushState(null, '', url.toString())
  }

  const tabClass = (key: JobTabKey) => `tab${activeTab === key ? ' active' : ''}`

  return (
    <div class="container">
      <div class="header">
        <h1><a href="/_profiler?section=jobs"><span class="h1-emoji">⚙️</span> Job Profile</a></h1>
        <p>{profile.path}</p>
        <div class="profiler-flex profiler-flex--gap-4 profiler-mt-2">
          <span>Duration: <strong>{profile.duration.toFixed(2)} ms</strong></span>
          <span>Status: <strong>
            <span class={`badge-${isFailed ? 'error' : 'success'}`}>
              {isFailed ? 'Failed' : 'Completed'}
            </span>
          </strong></span>
          {profile.memory != null && (
            <span>Memory: <strong>{(profile.memory / 1024 / 1024).toFixed(2)} MB</strong></span>
          )}
        </div>
        {parent && (
          <div class="profiler-flex profiler-flex--gap-2 profiler-mt-2 profiler-text--sm">
            <span style="color:var(--profiler-text-muted)">Triggered by:</span>
            {parent.profile_type === 'http' ? (
              <span><strong>{parent.method}</strong> {parent.path} · {parent.http_status} · {parent.duration?.toFixed(2)} ms</span>
            ) : (
              <span>⚙️ <strong>{parent.path}</strong> · {parent.duration?.toFixed(2)} ms</span>
            )}
            <a href={`/_profiler/profiles/${parent.token}`} style="color: var(--profiler-accent);">View →</a>
          </div>
        )}
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          <a href="#" class={tabClass('job')} onClick={handleTabClick('job')}>Job</a>
          <a href="#" class={tabClass('database')} onClick={handleTabClick('database')}>Database</a>
          <a href="#" class={tabClass('cache')} onClick={handleTabClick('cache')}>Cache</a>
          {hasHttp && (
            <a href="#" class={tabClass('http')} onClick={handleTabClick('http')}>Outbound HTTP</a>
          )}
          {hasJobs && (
            <a href="#" class={tabClass('jobs')} onClick={handleTabClick('jobs')}>Jobs ({profile.child_jobs!.length})</a>
          )}
        </div>

        <div class="profiler-p-4 tab-content active">
          {activeTab === 'job' && <JobTab jobData={cd['job'] as any} />}
          {activeTab === 'database' && <DatabaseTab dbData={cd['database'] as any} token={profile.token} />}
          {activeTab === 'cache' && <CacheTab cacheData={cd['cache'] as any} />}
          {activeTab === 'http' && <HttpTab httpData={cd['http'] as any} />}
          {activeTab === 'jobs' && <JobsTab jobs={profile.child_jobs!} />}
        </div>
      </div>

      {!embedded && (
        <div class="profiler-mt-6">
          <a href="/_profiler" style="color: var(--profiler-accent);">← Back to profiles</a>
        </div>
      )}
    </div>
  )
}
