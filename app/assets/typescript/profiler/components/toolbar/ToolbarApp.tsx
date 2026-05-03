import { Profile, DatabaseData, AjaxData, PerformanceData, ViewData, CacheData, DumpData, HttpData, LogData, ExceptionData, RoutesData, I18nData, EnvData, MailerData } from '../../dashboard/types'
import { ToolbarItem } from './ToolbarItem'
import { RequestPanel } from './panels/RequestPanel'
import { DatabasePanel } from './panels/DatabasePanel'
import { AjaxPanel } from './panels/AjaxPanel'
import { EventsPanel } from './panels/EventsPanel'
import { ViewsPanel } from './panels/ViewsPanel'
import { CachePanel } from './panels/CachePanel'
import { DumpsPanel } from './panels/DumpsPanel'
import { HttpPanel } from './panels/HttpPanel'
import { LogsPanel } from './panels/LogsPanel'
import { ExceptionPanel } from './panels/ExceptionPanel'
import { RoutesPanel } from './panels/RoutesPanel'
import { I18nPanel } from './panels/I18nPanel'
import { JobsPanel } from './panels/JobsPanel'
import { EnvPanel } from './panels/EnvPanel'
import { MailerPanel } from './panels/MailerPanel'

interface Props {
  profile: Profile
  token: string
}

function statusClass(status: number): string {
  if (status >= 200 && status < 300) return 'profiler-text--success'
  if (status >= 300 && status < 400) return 'profiler-text--warning'
  if (status >= 400) return 'profiler-text--error'
  return ''
}

function durationClass(duration: number): string {
  if (duration < 100) return 'profiler-text--success'
  if (duration < 500) return 'profiler-text--warning'
  return 'profiler-text--error'
}

function formatTime(iso: string): string {
  return new Date(iso).toLocaleTimeString('en', {
    hour12: false,
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  })
}

export function ToolbarApp({ profile, token }: Props) {
  const cd = profile.collectors_data || {}
  const requestData = cd['request'] as Record<string, any> | undefined
  const dbData = cd['database'] as DatabaseData | undefined
  const ajaxData = cd['ajax'] as AjaxData | undefined
  const perfData = cd['performance'] as PerformanceData | undefined
  const viewData = cd['view'] as ViewData | undefined
  const cacheData = cd['cache'] as CacheData | undefined
  const dumpData = cd['dump'] as DumpData | undefined
  const httpData = cd['http'] as HttpData | undefined
  const logData = cd['logs'] as LogData | undefined
  const exceptionData = cd['exception'] as ExceptionData | undefined
  const routesData = cd['routes'] as RoutesData | undefined
  const i18nData = cd['i18n'] as I18nData | undefined
  const envData = cd['env'] as EnvData | undefined
  const mailerData = cd['mailer'] as MailerData | undefined
  const childJobs = profile.child_jobs ?? []

  const reqClass = statusClass(profile.status)
  const durClass = durationClass(profile.duration)
  const dbClass = (dbData?.slow_queries ?? 0) > 0 ? 'profiler-text--error' : 'profiler-text--success'
  const ajaxClass = (ajaxData?.total_requests ?? 0) > 20 ? 'profiler-text--error' : 'profiler-text--success'
  const cacheClass = (cacheData?.hit_rate ?? 0) > 80 ? 'profiler-text--success' : 'profiler-text--warning'

  return (
    <>
      <div class="profiler-toolbar-container">
      {requestData && (
        <>
          <ToolbarItem
            href={`/_profiler/profiles/${token}?tab=request`}
            className={reqClass}
            panelLarge
            panel={<RequestPanel profile={profile} requestData={requestData} />}
          >
            <span class="profiler-text--muted profiler-text--xs">{profile.method}</span>
            <span>{profile.status}</span>
          </ToolbarItem>

          <ToolbarItem
            href={`/_profiler/profiles/${token}?tab=request`}
            className={durClass}
            panel={
              <>
                <div class="profiler-toolbar-panel-header">Performance</div>
                <div class="profiler-toolbar-panel-content">
                  <div class="profiler-toolbar-panel-row">
                    <span>Duration</span>
                    <strong class={durClass}>{profile.duration.toFixed(2)} ms</strong>
                  </div>
                  {profile.memory && (
                    <div class="profiler-toolbar-panel-row">
                      <span>Memory</span>
                      <strong>{(profile.memory / 1024 / 1024).toFixed(2)} MB</strong>
                    </div>
                  )}
                  <div class="profiler-toolbar-panel-row">
                    <span>Started</span>
                    <strong>{formatTime(profile.started_at)}</strong>
                  </div>
                </div>
              </>
            }
          >
            <span class={durClass}>{profile.duration.toFixed(2)}</span>
            <span class="profiler-text--muted profiler-text--xs">ms</span>
          </ToolbarItem>
        </>
      )}

      {dbData?.total_queries !== undefined && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=database`}
          className={dbClass}
          panelLarge
          panel={<DatabasePanel dbData={dbData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">DB</span>
          <span>{dbData.total_queries}</span>
          {(dbData.slow_queries ?? 0) > 0 && (
            <span class="profiler-text--error profiler-text--xs">▲ {dbData.slow_queries}</span>
          )}
          <span class="profiler-text--muted profiler-text--xs">{dbData.total_duration.toFixed(1)}ms</span>
        </ToolbarItem>
      )}

      {ajaxData && ajaxData.total_requests > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=ajax`}
          className={ajaxClass}
          panelLarge
          panel={<AjaxPanel ajaxData={ajaxData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">XHR</span>
          <span>{ajaxData.total_requests}</span>
          <span class="profiler-text--muted profiler-text--xs">{ajaxData.total_duration.toFixed(1)}ms</span>
        </ToolbarItem>
      )}

      {perfData?.events && perfData.total_events > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=timeline`}
          panel={<EventsPanel perfData={perfData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">EVT</span>
          <span>{perfData.total_events}</span>
        </ToolbarItem>
      )}

      {viewData?.total_views !== undefined && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=views`}
          panel={<ViewsPanel viewData={viewData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">VIEW</span>
          <span>{viewData.total_views}</span>
          {viewData.total_partials > 0 && (
            <span class="profiler-text--muted profiler-text--xs">+{viewData.total_partials}p</span>
          )}
        </ToolbarItem>
      )}

      {cacheData && cacheData.total_reads > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=cache`}
          className={cacheClass}
          panel={<CachePanel cacheData={cacheData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">CACHE</span>
          <span class={cacheClass}>{cacheData.hit_rate}%</span>
        </ToolbarItem>
      )}

      {httpData && httpData.total_requests > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=http`}
          className={(httpData.error_requests > 0 || httpData.slow_requests > 0) ? 'profiler-text--error' : 'profiler-text--success'}
          panelLarge
          panel={<HttpPanel httpData={httpData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">HTTP</span>
          <span>{httpData.total_requests}</span>
          {httpData.slow_requests > 0 && (
            <span class="profiler-text--error profiler-text--xs">▲ {httpData.slow_requests}</span>
          )}
          <span class="profiler-text--muted profiler-text--xs">{httpData.total_duration.toFixed(1)}ms</span>
        </ToolbarItem>
      )}

      {dumpData && dumpData.count > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=dump`}
          className="profiler-text--warning"
          panelLarge
          panel={<DumpsPanel dumpData={dumpData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">DUMP</span>
          <span class="profiler-text--warning">{dumpData.count}</span>
        </ToolbarItem>
      )}

      {logData && logData.count > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=logs`}
          className={logData.errors > 0 ? 'profiler-text--error' : logData.warnings > 0 ? 'profiler-text--warning' : 'profiler-text--muted'}
          panelLarge
          panel={<LogsPanel logData={logData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">LOG</span>
          <span class={logData.errors > 0 ? 'profiler-text--error' : logData.warnings > 0 ? 'profiler-text--warning' : ''}>
            {logData.errors > 0 ? logData.errors : logData.warnings > 0 ? logData.warnings : logData.count}
          </span>
        </ToolbarItem>
      )}

      {exceptionData && exceptionData.exception_class && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=exception`}
          className="profiler-text--error"
          panelLarge
          panel={<ExceptionPanel exceptionData={exceptionData} />}
        >
          <span class="profiler-text--error profiler-text--xs">💥</span>
          <span class="profiler-text--error profiler-text--xs">{exceptionData.exception_class.split('::').pop()}</span>
        </ToolbarItem>
      )}

      {routesData && routesData.total > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=routes`}
          panelLarge
          panel={<RoutesPanel routesData={routesData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">ROUTE</span>
          <span class="profiler-text--xs profiler-text--mono">
            {routesData.matched?.pattern ?? '—'}
          </span>
        </ToolbarItem>
      )}

      {i18nData && i18nData.total > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=i18n`}
          className={i18nData.missing_count > 0 ? 'profiler-text--error' : 'profiler-text--muted'}
          panel={<I18nPanel i18nData={i18nData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">I18N</span>
          <span class="profiler-text--xs profiler-text--mono">{i18nData.locale}</span>
          {i18nData.missing_count > 0 && (
            <span class="profiler-text--error profiler-text--xs">⚠ {i18nData.missing_count}</span>
          )}
        </ToolbarItem>
      )}

      {childJobs.length > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=jobs`}
          className={childJobs.some(j => j.status === 'failed') ? 'profiler-text--error' : 'profiler-text--success'}
          panelLarge
          panel={<JobsPanel jobs={childJobs} />}
        >
          <span class="profiler-text--muted profiler-text--xs">JOB</span>
          <span>{childJobs.length}</span>
          {childJobs.some(j => j.status === 'failed') && (
            <span class="profiler-text--error profiler-text--xs">✗</span>
          )}
        </ToolbarItem>
      )}

      {mailerData && mailerData.total > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=mailer`}
          className={mailerData.failed > 0 ? 'profiler-text--error' : 'profiler-text--success'}
          panelLarge
          panel={<MailerPanel mailerData={mailerData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">✉️</span>
          <span>{mailerData.total}</span>
          {mailerData.failed > 0 && (
            <span class="profiler-text--error profiler-text--xs">⚠ {mailerData.failed}</span>
          )}
        </ToolbarItem>
      )}

      {envData && envData.total > 0 && (
        <ToolbarItem
          href={`/_profiler/profiles/${token}?tab=env`}
          panel={<EnvPanel envData={envData} />}
        >
          <span class="profiler-text--muted profiler-text--xs">ENV</span>
          <span class="profiler-text--muted">{envData.total}</span>
        </ToolbarItem>
      )}

      <a href="/_profiler" class="profiler-toolbar-item profiler-toolbar-logo">&#11041; Profiler</a>
    </div>
    </>
  )
}
