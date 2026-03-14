import { DumpData } from '../../../dashboard/types'

interface Props {
  dumpData: DumpData
}

export function DumpsPanel({ dumpData }: Props) {
  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Dumps ({dumpData.count})
      </div>
      <div class="profiler-toolbar-panel-content">
        {dumpData.dumps.slice(0, 5).map((dump, index) => (
          <div key={index} class="profiler-dump-card">
            <div class="profiler-dump-card__header">
              <span class="profiler-text--xs profiler-text--muted">
                #{index + 1}
                {dump.label && (
                  <> · <strong class="profiler-text--warning">{dump.label}</strong></>
                )}
              </span>
              <span class="profiler-text--xs profiler-text--muted">
                {dump.file.split('/').pop()}:{dump.line}
              </span>
            </div>
            <pre
              class="profiler-text--xs profiler-text--truncate profiler-text--warning"
              style={{ margin: 0, background: 'none', border: 'none', padding: 0 }}
            >
              {(dump.formatted.split('\n')[0] || dump.formatted).trim()}
            </pre>
          </div>
        ))}
        {dumpData.count > 5 && (
          <div class="profiler-more">+ {dumpData.count - 5} more dumps</div>
        )}
      </div>
    </>
  )
}
