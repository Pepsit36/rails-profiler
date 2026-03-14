import { useState } from 'preact/hooks'
import { Profile } from '../../dashboard/types'
import { RequestTab } from './tabs/RequestTab'
import { DatabaseTab } from './tabs/DatabaseTab'
import { DumpsTab } from './tabs/DumpsTab'
import { TimelineTab } from './tabs/TimelineTab'
import { ViewsTab } from './tabs/ViewsTab'
import { AjaxTab } from './tabs/AjaxTab'
import { CacheTab } from './tabs/CacheTab'
import { HttpTab } from './tabs/HttpTab'

type TabKey = 'request' | 'dump' | 'database' | 'ajax' | 'http' | 'timeline' | 'views' | 'cache'

interface Props {
  profile: Profile
  initialTab: TabKey
  embedded: boolean
}

export function ProfileDashboard({ profile, initialTab, embedded }: Props) {
  const [activeTab, setActiveTab] = useState<TabKey>(initialTab)
  const cd = profile.collectors_data || {}
  const hasAjax = (cd['ajax'] as any)?.total_requests > 0
  const hasHttp = (cd['http'] as any)?.total_requests > 0

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
        <h1>📊 Profile Details</h1>
        <p>{profile.method} {profile.path}</p>
        <div class="profiler-flex profiler-flex--gap-4 profiler-mt-2">
          <span>Duration: <strong>{profile.duration.toFixed(2)} ms</strong></span>
          <span>Status: <strong>{profile.status}</strong></span>
          {profile.memory && (
            <span>Memory: <strong>{(profile.memory / 1024 / 1024).toFixed(2)} MB</strong></span>
          )}
        </div>
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="tabs">
          <a href="#" class={tabClass('request')} onClick={handleTabClick('request')}>Request</a>
          <a href="#" class={tabClass('dump')} onClick={handleTabClick('dump')}>Dump</a>
          <a href="#" class={tabClass('database')} onClick={handleTabClick('database')}>Database</a>
          {hasAjax && (
            <a href="#" class={tabClass('ajax')} onClick={handleTabClick('ajax')}>AJAX</a>
          )}
          {hasHttp && (
            <a href="#" class={tabClass('http')} onClick={handleTabClick('http')}>HTTP</a>
          )}
          <a href="#" class={tabClass('timeline')} onClick={handleTabClick('timeline')}>Timeline</a>
          <a href="#" class={tabClass('views')} onClick={handleTabClick('views')}>Views</a>
          <a href="#" class={tabClass('cache')} onClick={handleTabClick('cache')}>Cache</a>
        </div>

        <div class="profiler-p-4 tab-content active">
          {activeTab === 'request' && <RequestTab profile={profile} />}
          {activeTab === 'dump' && <DumpsTab dumpData={cd['dump'] as any} />}
          {activeTab === 'database' && <DatabaseTab dbData={cd['database'] as any} />}
          {activeTab === 'ajax' && <AjaxTab ajaxData={cd['ajax'] as any} />}
          {activeTab === 'http' && <HttpTab httpData={cd['http'] as any} />}
          {activeTab === 'timeline' && <TimelineTab perfData={cd['performance'] as any} />}
          {activeTab === 'views' && <ViewsTab viewData={cd['view'] as any} />}
          {activeTab === 'cache' && <CacheTab cacheData={cd['cache'] as any} />}
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
