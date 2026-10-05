import { useState } from 'preact/hooks'
import { Profile } from '../../dashboard/types'
import { ConsoleTab } from './tabs/ConsoleTab'
import { DatabaseTab } from './tabs/DatabaseTab'
import { CacheTab } from './tabs/CacheTab'
import { HttpTab } from './tabs/HttpTab'
import { DumpsTab } from './tabs/DumpsTab'
import { LogsTab } from './tabs/LogsTab'
import { ExceptionTab } from './tabs/ExceptionTab'
import { EnvTab } from './tabs/EnvTab'
import { FlameGraphTab } from './tabs/FlameGraphTab'
import { getGemVersion, allocatedObjects, formatAllocations, ALLOCATIONS_HINT } from '../../dashboard/utils'

type ConsoleTabKey = 'console' | 'database' | 'cache' | 'http' | 'dump' | 'logs' | 'exception' | 'env' | 'timeline'

interface Props {
  profile: Profile
  initialTab: string
  embedded: boolean
}

export function ConsoleProfileDashboard({ profile, initialTab, embedded }: Props) {
  const cd = profile.collectors_data || {}
  const hasHttp = (cd['http'] as any)?.total_requests > 0
  const hasDumps = ((cd['dump'] as any)?.count ?? 0) > 0
  const hasLogs = ((cd['logs'] as any)?.total ?? 0) > 0
  const hasException = !!(cd['exception'] as any)?.exception_class
  const consoleData = cd['console'] as any

  const validTabs: ConsoleTabKey[] = ['console', 'database', 'cache', 'http', 'dump', 'logs', 'exception', 'env', 'timeline']
  const defaultTab: ConsoleTabKey = validTabs.includes(initialTab as ConsoleTabKey) ? (initialTab as ConsoleTabKey) : 'console'
  const [activeTab, setActiveTab] = useState<ConsoleTabKey>(hasException ? 'exception' : defaultTab)
  const isFailed = profile.status === 500

  const handleTabClick = (tab: ConsoleTabKey) => (e: MouseEvent) => {
    e.preventDefault()
    setActiveTab(tab)
    const url = new URL(window.location.href)
    url.searchParams.set('tab', tab)
    history.pushState(null, '', url.toString())
  }

  const tabClass = (key: ConsoleTabKey) => `tab${activeTab === key ? ' active' : ''}`

  return (
    <div class="container">
      <div class="header">
        <h1><a href="/_profiler?section=console"><span class="h1-emoji">{'>_'}</span> Console Profile</a></h1>
        <p style="font-family: monospace; word-break: break-all">{profile.path}</p>
        <div class="profiler-flex profiler-flex--gap-4 profiler-mt-2">
          <span>Duration: <strong>{profile.duration.toFixed(2)} ms</strong></span>
          <span>Status: <strong>
            <span class={`badge-${isFailed ? 'error' : 'success'}`}>
              {isFailed ? 'Error' : 'OK'}
            </span>
          </strong></span>
          {allocatedObjects(profile) != null && (
            <span title={ALLOCATIONS_HINT}>Allocations: <strong>{formatAllocations(allocatedObjects(profile))}</strong></span>
          )}
          {profile.gem_version && <span class="profiler-version-badge">v{profile.gem_version}</span>}
        </div>
        {profile.gem_version && profile.gem_version !== getGemVersion() && (
          <div class="profiler-version-mismatch">
            ⚠️ Profil capturé avec la version <strong>{profile.gem_version}</strong> — version actuelle : <strong>{getGemVersion()}</strong>
          </div>
        )}
      </div>

      <div class="profiler-panel">
        <div class="tabs">
          <a href="#" class={tabClass('console')} onClick={handleTabClick('console')}>Console</a>
          <a href="#" class={tabClass('database')} onClick={handleTabClick('database')}>Database</a>
          <a href="#" class={tabClass('cache')} onClick={handleTabClick('cache')}>Cache</a>
          {hasHttp && <a href="#" class={tabClass('http')} onClick={handleTabClick('http')}>HTTP</a>}
          {hasDumps && <a href="#" class={tabClass('dump')} onClick={handleTabClick('dump')}>Dumps</a>}
          {hasLogs && <a href="#" class={tabClass('logs')} onClick={handleTabClick('logs')}>Logs</a>}
          {hasException && <a href="#" class={tabClass('exception')} onClick={handleTabClick('exception')}>Exception</a>}
          <a href="#" class={tabClass('env')} onClick={handleTabClick('env')}>Env</a>
          <a href="#" class={tabClass('timeline')} onClick={handleTabClick('timeline')}>Timeline</a>
        </div>

        <div class="profiler-p-0 tab-content active">
          {activeTab === 'console' && consoleData && <ConsoleTab data={consoleData} />}
          {activeTab === 'database' && <DatabaseTab dbData={cd['database'] as any} token={profile.token} />}
          {activeTab === 'cache' && <CacheTab cacheData={cd['cache'] as any} />}
          {activeTab === 'http' && hasHttp && <HttpTab httpData={cd['http'] as any} />}
          {activeTab === 'dump' && hasDumps && <DumpsTab dumpData={cd['dump'] as any} />}
          {activeTab === 'logs' && hasLogs && <LogsTab logData={cd['logs'] as any} />}
          {activeTab === 'exception' && hasException && <ExceptionTab exceptionData={cd['exception'] as any} />}
          {activeTab === 'env' && <EnvTab envData={cd['env'] as any} readOnly />}
          {activeTab === 'timeline' && <FlameGraphTab flamegraphData={cd['flamegraph'] as any} perfData={cd['performance'] as any} functionProfileData={cd['function_profile'] as any} />}
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
