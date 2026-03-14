import { CacheData } from '../../../dashboard/types'

interface Props {
  cacheData: CacheData
}

export function CachePanel({ cacheData }: Props) {
  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Cache
        <span class="profiler-float-right">Hit rate: {cacheData.hit_rate}%</span>
      </div>
      <div class="profiler-toolbar-panel-content">
        <div class="profiler-toolbar-panel-row">
          <span>Reads</span>
          <strong>{cacheData.total_reads}</strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Writes</span>
          <strong>{cacheData.total_writes}</strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Hits</span>
          <strong class="profiler-text--success">{cacheData.hits}</strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Misses</span>
          <strong class="profiler-text--error">{cacheData.misses}</strong>
        </div>
      </div>
    </>
  )
}
