import { useState } from 'preact/hooks'
import { LogData, LogEntry } from '../../../dashboard/types'

interface Props {
  logData: LogData | undefined
}

type LevelFilter = 'ALL' | 'DEBUG' | 'INFO' | 'WARN' | 'ERROR' | 'FATAL'

function levelClass(level: string): string {
  switch (level) {
    case 'ERROR':
    case 'FATAL':
      return 'profiler-text--error'
    case 'WARN':
      return 'profiler-text--warning'
    case 'INFO':
      return 'profiler-text--success'
    default:
      return 'profiler-text--muted'
  }
}

function levelBadgeStyle(level: string): string {
  switch (level) {
    case 'ERROR':
    case 'FATAL':
      return 'background: var(--profiler-error, #ef4444); color: #fff;'
    case 'WARN':
      return 'background: var(--profiler-warning, #f59e0b); color: #fff;'
    case 'INFO':
      return 'background: var(--profiler-success, #22c55e); color: #fff;'
    default:
      return 'background: var(--profiler-muted, #6b7280); color: #fff;'
  }
}

export function LogsTab({ logData }: Props) {
  const [filter, setFilter] = useState<LevelFilter>('ALL')

  if (!logData?.logs?.length) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">📋</div>
        <h3 class="profiler-empty__title">No log messages captured</h3>
        <div class="profiler-empty__description">
          <p>Log messages emitted via <code>Rails.logger</code> during this request will appear here.</p>
        </div>
      </div>
    )
  }

  const levels: LevelFilter[] = ['ALL', 'DEBUG', 'INFO', 'WARN', 'ERROR', 'FATAL']
  const filtered = filter === 'ALL' ? logData.logs : logData.logs.filter((l: LogEntry) => l.level === filter)

  return (
    <>
      <h2 class="profiler-section__header">Log Messages ({logData.count})</h2>

      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        {logData.errors > 0 && (
          <span>Errors: <strong class="profiler-text--error">{logData.errors}</strong></span>
        )}
        {logData.warnings > 0 && (
          <span>Warnings: <strong class="profiler-text--warning">{logData.warnings}</strong></span>
        )}
      </div>

      <div class="profiler-flex profiler-flex--gap-2 profiler-mb-4">
        {levels.map(level => (
          <button
            key={level}
            onClick={() => setFilter(level)}
            class={`btn btn-sm ${filter === level ? 'btn-primary' : 'btn-secondary'}`}
          >
            {level}
          </button>
        ))}
      </div>

      {filtered.length === 0 ? (
        <div class="profiler-text--muted profiler-text--sm">No {filter} messages.</div>
      ) : (
        filtered.map((entry: LogEntry, index: number) => (
          <div key={index} class="profiler-query-card profiler-mb-2">
            <div class="profiler-query-card__header">
              <span
                class="profiler-text--xs"
                style={`display:inline-block;padding:1px 6px;border-radius:3px;font-weight:600;${levelBadgeStyle(entry.level)}`}
              >
                {entry.level}
              </span>
              <span class="profiler-text--xs profiler-text--muted">
                {new Date(entry.timestamp).toLocaleTimeString('en', { hour12: false })}
              </span>
            </div>
            <pre class={`profiler-query-card__code ${levelClass(entry.level)}`} style="white-space:pre-wrap;word-break:break-all;">
              {entry.message}
            </pre>
          </div>
        ))
      )}
    </>
  )
}
