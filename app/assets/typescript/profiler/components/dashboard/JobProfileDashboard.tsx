import { useState } from 'preact/hooks'
import { Profile } from '../../dashboard/types'
import { JobTab } from './tabs/JobTab'
import { DatabaseTab } from './tabs/DatabaseTab'
import { CacheTab } from './tabs/CacheTab'
import { HttpTab } from './tabs/HttpTab'
import { JobsTab } from './tabs/JobsTab'
import { DumpsTab } from './tabs/DumpsTab'
import { LogsTab } from './tabs/LogsTab'
import { ExceptionTab } from './tabs/ExceptionTab'
import { EnvTab } from './tabs/EnvTab'
import { FlameGraphTab } from './tabs/FlameGraphTab'
import { MailerTab } from './tabs/MailerTab'
import { getGemVersion } from '../../dashboard/utils'

type JobTabKey = 'job' | 'database' | 'cache' | 'http' | 'jobs' | 'dump' | 'logs' | 'exception' | 'env' | 'timeline' | 'mailer'

interface Props {
  profile: Profile
  initialTab: string
  embedded: boolean
}

export function JobProfileDashboard({ profile, initialTab, embedded }: Props) {
  const cd = profile.collectors_data || {}
  const hasHttp = (cd['http'] as any)?.total_requests > 0
  const hasJobs = (profile.child_jobs?.length ?? 0) > 0
  const hasDumps = ((cd['dump'] as any)?.count ?? 0) > 0
  const hasLogs = ((cd['logs'] as any)?.total ?? 0) > 0
  const hasException = !!(cd['exception'] as any)?.exception_class
  const hasMailers = ((cd['mailer'] as any)?.total ?? 0) > 0

  const validTabs: JobTabKey[] = ['job', 'database', 'cache', 'http', 'jobs', 'dump', 'logs', 'exception', 'env', 'timeline', 'mailer']
  const defaultTab: JobTabKey = validTabs.includes(initialTab as JobTabKey) ? (initialTab as JobTabKey) : 'job'
  const [activeTab, setActiveTab] = useState<JobTabKey>(hasException ? 'exception' : defaultTab)
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
          {profile.gem_version && <span class="profiler-version-badge">v{profile.gem_version}</span>}
        </div>
        {profile.gem_version && profile.gem_version !== getGemVersion() && (
          <div class="profiler-version-mismatch">
            ⚠️ Profil capturé avec la version <strong>{profile.gem_version}</strong> — version actuelle : <strong>{getGemVersion()}</strong>
          </div>
        )}
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
          {hasException && (
            <a href="#" class={tabClass('exception')} onClick={handleTabClick('exception')} style="color:var(--profiler-error,#ef4444);">💥 Exception</a>
          )}
          <a href="#" class={tabClass('job')} onClick={handleTabClick('job')}>Job</a>
          <a href="#" class={tabClass('database')} onClick={handleTabClick('database')}>Database</a>
          <a href="#" class={tabClass('cache')} onClick={handleTabClick('cache')}>Cache</a>
          {hasHttp && (
            <a href="#" class={tabClass('http')} onClick={handleTabClick('http')}>Outbound HTTP</a>
          )}
          <a href="#" class={tabClass('timeline')} onClick={handleTabClick('timeline')}>Timeline</a>
          {hasJobs && (
            <a href="#" class={tabClass('jobs')} onClick={handleTabClick('jobs')}>Jobs ({profile.child_jobs!.length})</a>
          )}
          {hasDumps && (
            <a href="#" class={tabClass('dump')} onClick={handleTabClick('dump')}>Dumps ({(cd['dump'] as any).count})</a>
          )}
          {hasLogs && (
            <a href="#" class={tabClass('logs')} onClick={handleTabClick('logs')}>Logs</a>
          )}
          {hasMailers && (
            <a href="#" class={tabClass('mailer')} onClick={handleTabClick('mailer')}>Mailers</a>
          )}
          <a href="#" class={tabClass('env')} onClick={handleTabClick('env')}>Env</a>
        </div>

        <div class="profiler-p-4 tab-content active">
          {activeTab === 'exception' && <ExceptionTab exceptionData={cd['exception'] as any} />}
          {activeTab === 'job' && <JobTab jobData={cd['job'] as any} />}
          {activeTab === 'database' && <DatabaseTab dbData={cd['database'] as any} token={profile.token} />}
          {activeTab === 'cache' && <CacheTab cacheData={cd['cache'] as any} />}
          {activeTab === 'http' && <HttpTab httpData={cd['http'] as any} />}
          {activeTab === 'timeline' && <FlameGraphTab flamegraphData={cd['flamegraph'] as any} perfData={cd['performance'] as any} functionProfileData={cd['function_profile'] as any} />}
          {activeTab === 'jobs' && <JobsTab jobs={profile.child_jobs!} />}
          {activeTab === 'dump' && <DumpsTab dumpData={cd['dump'] as any} />}
          {activeTab === 'logs' && <LogsTab logData={cd['logs'] as any} />}
          {activeTab === 'mailer' && <MailerTab mailerData={cd['mailer'] as any} />}
          {activeTab === 'env' && <EnvTab envData={cd['env'] as any} readOnly />}
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
