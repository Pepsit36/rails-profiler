import { useState } from 'preact/hooks'
import { Profile } from '../../dashboard/types'
import { TestTab } from './tabs/TestTab'
import { DatabaseTab } from './tabs/DatabaseTab'
import { CacheTab } from './tabs/CacheTab'
import { DumpsTab } from './tabs/DumpsTab'
import { LogsTab } from './tabs/LogsTab'
import { ExceptionTab } from './tabs/ExceptionTab'
import { EnvTab } from './tabs/EnvTab'
import { FlameGraphTab } from './tabs/FlameGraphTab'

type TestTabKey = 'test' | 'database' | 'cache' | 'dump' | 'logs' | 'exception' | 'env' | 'timeline'

interface Props {
  profile: Profile
  initialTab: string
  embedded: boolean
}

export function TestProfileDashboard({ profile, initialTab, embedded }: Props) {
  const cd = profile.collectors_data || {}
  const hasDumps = ((cd['dump'] as any)?.count ?? 0) > 0
  const hasLogs = ((cd['logs'] as any)?.total ?? 0) > 0
  const hasException = !!(cd['exception'] as any)?.exception_class
  const testData = cd['test'] as any

  const validTabs: TestTabKey[] = ['test', 'database', 'cache', 'dump', 'logs', 'exception', 'env', 'timeline']
  const defaultTab: TestTabKey = validTabs.includes(initialTab as TestTabKey) ? (initialTab as TestTabKey) : 'test'
  const [activeTab, setActiveTab] = useState<TestTabKey>(hasException ? 'exception' : defaultTab)

  const isFailed = profile.status === 500
  const testStatus = testData?.status || (isFailed ? 'failed' : 'passed')

  const handleTabClick = (tab: TestTabKey) => (e: MouseEvent) => {
    e.preventDefault()
    setActiveTab(tab)
    const url = new URL(window.location.href)
    url.searchParams.set('tab', tab)
    history.pushState(null, '', url.toString())
  }

  const tabClass = (key: TestTabKey) => `tab${activeTab === key ? ' active' : ''}`

  return (
    <div class="container">
      <div class="header">
        <h1><a href="/_profiler?section=tests"><span class="h1-emoji">🧪</span> Test Profile</a></h1>
        <p style="word-break: break-word">{testData?.test_name || profile.path}</p>
        <div class="profiler-flex profiler-flex--gap-4 profiler-mt-2">
          <span>Duration: <strong>{profile.duration.toFixed(2)} ms</strong></span>
          <span>Status: <strong>
            <span class={`badge-${isFailed ? 'error' : testStatus === 'pending' ? 'warning' : 'success'}`}>
              {testStatus === 'failed' ? '✗ Failed' : testStatus === 'pending' ? '⏸ Pending' : '✓ Passed'}
            </span>
          </strong></span>
          {profile.memory != null && (
            <span>Memory: <strong>{(profile.memory / 1024 / 1024).toFixed(2)} MB</strong></span>
          )}
        </div>
        {testData?.test_file && (
          <div class="profiler-text--xs profiler-text--muted profiler-mt-2">
            <span class="profiler-text--mono">{testData.test_file}:{testData.test_line}</span>
            <span style="margin-left: 8px">· {testData.framework}</span>
          </div>
        )}
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          {hasException && (
            <a href="#" class={tabClass('exception')} onClick={handleTabClick('exception')} style="color:var(--profiler-error,#ef4444);">💥 Exception</a>
          )}
          <a href="#" class={tabClass('test')} onClick={handleTabClick('test')}>Test</a>
          <a href="#" class={tabClass('database')} onClick={handleTabClick('database')}>Database</a>
          <a href="#" class={tabClass('cache')} onClick={handleTabClick('cache')}>Cache</a>
          <a href="#" class={tabClass('timeline')} onClick={handleTabClick('timeline')}>Timeline</a>
          {hasDumps && (
            <a href="#" class={tabClass('dump')} onClick={handleTabClick('dump')}>Dumps ({(cd['dump'] as any).count})</a>
          )}
          {hasLogs && (
            <a href="#" class={tabClass('logs')} onClick={handleTabClick('logs')}>Logs</a>
          )}
          <a href="#" class={tabClass('env')} onClick={handleTabClick('env')}>Env</a>
        </div>

        <div class="profiler-p-4 tab-content active">
          {activeTab === 'test' && testData && <TestTab testData={testData} />}
          {activeTab === 'database' && <DatabaseTab dbData={cd['database'] as any} token={profile.token} />}
          {activeTab === 'cache' && <CacheTab data={cd['cache'] as any} />}
          {activeTab === 'timeline' && (
            <FlameGraphTab data={cd['flamegraph'] as any} />
          )}
          {activeTab === 'dump' && hasDumps && <DumpsTab data={cd['dump'] as any} />}
          {activeTab === 'logs' && hasLogs && <LogsTab data={cd['logs'] as any} />}
          {activeTab === 'exception' && hasException && <ExceptionTab data={cd['exception'] as any} />}
          {activeTab === 'env' && <EnvTab envData={cd['env'] as any} />}
        </div>
      </div>
    </div>
  )
}
