import { LogData, LogEntry } from '../../../dashboard/types'

interface Props {
  logData: LogData
}

function levelColor(level: string): string {
  switch (level) {
    case 'ERROR':
    case 'FATAL':
      return 'var(--profiler-error, #ef4444)'
    case 'WARN':
      return 'var(--profiler-warning, #f59e0b)'
    case 'INFO':
      return 'var(--profiler-success, #22c55e)'
    default:
      return 'var(--profiler-muted, #6b7280)'
  }
}

export function LogsPanel({ logData }: Props) {
  const recent = logData.logs.slice(-5).reverse()

  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Logs ({logData.count})
        {logData.errors > 0 && (
          <span style="color:var(--profiler-error,#ef4444);margin-left:8px;">
            {logData.errors} error{logData.errors !== 1 ? 's' : ''}
          </span>
        )}
        {logData.warnings > 0 && logData.errors === 0 && (
          <span style="color:var(--profiler-warning,#f59e0b);margin-left:8px;">
            {logData.warnings} warning{logData.warnings !== 1 ? 's' : ''}
          </span>
        )}
      </div>
      <div class="profiler-toolbar-panel-content">
        {recent.map((entry: LogEntry, i: number) => (
          <div key={i} class="profiler-toolbar-panel-row" style="align-items:flex-start;gap:6px;">
            <span
              class="profiler-text--xs"
              style={`color:${levelColor(entry.level)};font-weight:600;min-width:40px;`}
            >
              {entry.level}
            </span>
            <span
              class="profiler-text--xs profiler-text--truncate"
              style="flex:1;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;"
            >
              {entry.message}
            </span>
          </div>
        ))}
        {logData.count > 5 && (
          <div class="profiler-more">+ {logData.count - 5} more messages</div>
        )}
      </div>
    </>
  )
}
