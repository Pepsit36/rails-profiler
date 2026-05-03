import { useState } from 'preact/hooks'
import { Profile } from '../../dashboard/types'
import { RequestTab } from './tabs/RequestTab'
import { DatabaseTab } from './tabs/DatabaseTab'
import { DumpsTab } from './tabs/DumpsTab'
import { FlameGraphTab } from './tabs/FlameGraphTab'
import { ViewsTab } from './tabs/ViewsTab'
import { AjaxTab } from './tabs/AjaxTab'
import { CacheTab } from './tabs/CacheTab'
import { HttpTab } from './tabs/HttpTab'
import { LogsTab } from './tabs/LogsTab'
import { ExceptionTab } from './tabs/ExceptionTab'
import { RoutesTab } from './tabs/RoutesTab'
import { I18nTab } from './tabs/I18nTab'
import { JobsTab } from './tabs/JobsTab'
import { EnvTab } from './tabs/EnvTab'
import { MailerTab } from './tabs/MailerTab'
import { getGemVersion } from '../../dashboard/utils'

type TabKey = 'request' | 'dump' | 'database' | 'ajax' | 'http' | 'timeline' | 'views' | 'cache' | 'logs' | 'exception' | 'routes' | 'i18n' | 'jobs' | 'env' | 'mailer'

interface Props {
  profile: Profile
  initialTab: TabKey
  embedded: boolean
}

export function ProfileDashboard({ profile, initialTab, embedded }: Props) {
  const cd = profile.collectors_data || {}
  const hasAjax = (cd['ajax'] as any)?.total_requests > 0
  const hasHttp = (cd['http'] as any)?.total_requests > 0
  const hasException = !!(cd['exception'] as any)?.exception_class
  const hasLogs = ((cd['logs'] as any)?.count ?? 0) > 0
  const hasRoutes = ((cd['routes'] as any)?.total ?? 0) > 0
  const hasI18n = ((cd['i18n'] as any)?.total ?? 0) > 0
  const hasJobs = (profile.child_jobs?.length ?? 0) > 0
  const hasMailers = ((cd['mailer'] as any)?.total ?? 0) > 0

  const [activeTab, setActiveTab] = useState<TabKey>(hasException ? 'exception' : initialTab)

  const handleTabClick = (tab: TabKey) => (e: MouseEvent) => {
    e.preventDefault()
    setActiveTab(tab)
    const url = new URL(window.location.href)
    url.searchParams.set('tab', tab)
    history.pushState(null, '', url.toString())
  }

  const tabClass = (key: TabKey) => `tab${activeTab === key ? ' active' : ''}`

  return (
    <div class="container">
      <div class="header">
        <h1><a href="/_profiler?section=http"><span class="h1-emoji">📊</span> Profile Details</a></h1>
        <p>{profile.method} {profile.path}</p>
        <div class="profiler-flex profiler-flex--gap-4 profiler-mt-2">
          <span>Duration: <strong>{profile.duration.toFixed(2)} ms</strong></span>
          <span>Status: <strong>{profile.status}</strong></span>
          {profile.memory && (
            <span>Memory: <strong>{(profile.memory / 1024 / 1024).toFixed(2)} MB</strong></span>
          )}
          <span style="color:var(--profiler-text-muted)">
            {new Date(profile.started_at).toLocaleString('en', { hour12: false, month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' })}
          </span>
          {profile.gem_version && <span class="profiler-version-badge">v{profile.gem_version}</span>}
        </div>
        {profile.gem_version && profile.gem_version !== getGemVersion() && (
          <div class="profiler-version-mismatch">
            ⚠️ Profil capturé avec la version <strong>{profile.gem_version}</strong> — version actuelle : <strong>{getGemVersion()}</strong>
          </div>
        )}
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          {hasException && (
            <a href="#" class={tabClass('exception')} onClick={handleTabClick('exception')} style="color:var(--profiler-error,#ef4444);">💥 Exception</a>
          )}
          <a href="#" class={tabClass('request')} onClick={handleTabClick('request')}>Request</a>
          <a href="#" class={tabClass('dump')} onClick={handleTabClick('dump')}>Dump</a>
          <a href="#" class={tabClass('database')} onClick={handleTabClick('database')}>Database</a>
          {hasAjax && (
            <a href="#" class={tabClass('ajax')} onClick={handleTabClick('ajax')}>AJAX</a>
          )}
          {hasHttp && (
            <a href="#" class={tabClass('http')} onClick={handleTabClick('http')}>Outbound HTTP</a>
          )}
          <a href="#" class={tabClass('timeline')} onClick={handleTabClick('timeline')}>Timeline</a>
          <a href="#" class={tabClass('views')} onClick={handleTabClick('views')}>Views</a>
          <a href="#" class={tabClass('cache')} onClick={handleTabClick('cache')}>Cache</a>
          {hasLogs && (
            <a href="#" class={tabClass('logs')} onClick={handleTabClick('logs')}>Logs</a>
          )}
          {hasRoutes && (
            <a href="#" class={tabClass('routes')} onClick={handleTabClick('routes')}>Routes</a>
          )}
          {hasI18n && (
            <a href="#" class={tabClass('i18n')} onClick={handleTabClick('i18n')}>I18n</a>
          )}
          {hasJobs && (
            <a href="#" class={tabClass('jobs')} onClick={handleTabClick('jobs')}>Jobs ({profile.child_jobs!.length})</a>
          )}
          {hasMailers && (
            <a href="#" class={tabClass('mailer')} onClick={handleTabClick('mailer')}>✉️ Mailers</a>
          )}
          <a href="#" class={tabClass('env')} onClick={handleTabClick('env')}>Env</a>
        </div>

        <div class="profiler-p-4 tab-content active">
          {activeTab === 'exception' && <ExceptionTab exceptionData={cd['exception'] as any} />}
          {activeTab === 'request' && <RequestTab profile={profile} />}
          {activeTab === 'dump' && <DumpsTab dumpData={cd['dump'] as any} />}
          {activeTab === 'database' && <DatabaseTab dbData={cd['database'] as any} token={profile.token} />}
          {activeTab === 'ajax' && <AjaxTab ajaxData={cd['ajax'] as any} />}
          {activeTab === 'http' && <HttpTab httpData={cd['http'] as any} />}
          {activeTab === 'timeline' && <FlameGraphTab flamegraphData={cd['flamegraph'] as any} perfData={cd['performance'] as any} functionProfileData={cd['function_profile'] as any} />}
          {activeTab === 'views' && <ViewsTab viewData={cd['view'] as any} />}
          {activeTab === 'cache' && <CacheTab cacheData={cd['cache'] as any} />}
          {activeTab === 'logs' && <LogsTab logData={cd['logs'] as any} />}
          {activeTab === 'routes' && <RoutesTab routesData={cd['routes'] as any} />}
          {activeTab === 'i18n' && <I18nTab i18nData={cd['i18n'] as any} />}
          {activeTab === 'jobs' && <JobsTab jobs={profile.child_jobs!} />}
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
