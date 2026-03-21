import { CacheData } from '../../../dashboard/types'

interface Props {
  cacheData: CacheData | undefined
}

export function CacheTab({ cacheData }: Props) {
  if (!cacheData) {
    return (
      <div class="profiler-empty">
        <p class="profiler-empty__description">No cache operations recorded</p>
      </div>
    )
  }

  return (
    <>
      <h2 class="profiler-section__header">Cache Operations</h2>
      <div class="profiler-flex profiler-flex--gap-4 profiler-mb-4 profiler-text--sm">
        <span>Reads: <strong>{cacheData.total_reads}</strong></span>
        <span>Writes: <strong>{cacheData.total_writes}</strong></span>
        <span>Deletes: <strong>{cacheData.total_deletes}</strong></span>
        <span>
          Hit Rate:{' '}
          <strong class={`badge-${cacheData.hit_rate > 80 ? 'success' : 'warning'}`}>
            {cacheData.hit_rate}%
          </strong>
        </span>
      </div>
      {cacheData.reads && cacheData.reads.length > 0 && (
        <>
          <h3 class="profiler-text--lg profiler-mt-6 profiler-mb-3">Cache Reads</h3>
          {cacheData.reads.map((read, i) => (
            <div key={i} class="profiler-query-card">
              <div class="profiler-query-card__header">
                <span class="profiler-text--mono profiler-text--sm">{read.key}</span>
                <div class="profiler-flex profiler-flex--gap-2">
                  <span class={read.hit ? 'badge-success' : 'badge-error'}>
                    {read.hit ? 'HIT' : 'MISS'}
                  </span>
                  <span class={read.duration >= 500 ? 'badge-error' : read.duration >= 100 ? 'badge-warning' : 'badge-success'}>{read.duration.toFixed(2)} ms</span>
                </div>
              </div>
            </div>
          ))}
        </>
      )}
    </>
  )
}
