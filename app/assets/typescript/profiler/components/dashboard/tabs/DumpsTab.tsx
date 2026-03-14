import { DumpData } from '../../../dashboard/types'

interface Props {
  dumpData: DumpData | undefined
}

export function DumpsTab({ dumpData }: Props) {
  if (!dumpData?.dumps?.length) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">🔍</div>
        <h3 class="profiler-empty__title">No dumps recorded</h3>
        <div class="profiler-empty__description">
          <p>Use <code>Profiler.dump(variable)</code> in your code to dump variables here.</p>
          <p class="profiler-mt-3">Example: <code>Profiler.dump(@user, "Current user")</code></p>
        </div>
      </div>
    )
  }

  return (
    <>
      <h2 class="profiler-section__header">Dumped Variables ({dumpData.count})</h2>
      {dumpData.dumps.map((dump, index) => (
        <div key={index} class="profiler-dump-card">
          <div class="profiler-dump-card__header">
            <div>
              <span class="profiler-text--xs profiler-text--muted">#{index + 1}</span>
              {dump.label && <span class="profiler-dump-card__label">{dump.label}</span>}
            </div>
            <div>
              <div class="profiler-dump-card__location">{dump.file}:{dump.line}</div>
              <div class="profiler-text--xs profiler-text--muted profiler-mt-1">
                {new Date(dump.timestamp).toLocaleTimeString('en', { hour12: false })}
              </div>
            </div>
          </div>
          <div class="profiler-dump-card__content">
            <pre>{dump.formatted}</pre>
          </div>
        </div>
      ))}
    </>
  )
}
