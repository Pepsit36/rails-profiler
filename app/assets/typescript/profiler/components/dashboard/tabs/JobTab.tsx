import { JobData } from '../../../dashboard/types'

interface Props {
  jobData: JobData | undefined
}

export function JobTab({ jobData }: Props) {
  if (!jobData) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">⚙️</div>
        <h3 class="profiler-empty__title">No job data</h3>
      </div>
    )
  }

  const isSuccess = jobData.status === 'completed'

  return (
    <>
      <h2 class="profiler-section__header">Job Details</h2>

      <div class="profiler-grid profiler-grid--2 profiler-mb-6">
        <div class="profiler-panel profiler-panel--sm">
          <h3 class="profiler-text--sm profiler-text--muted profiler-text--uppercase profiler-mb-3">Info</h3>
          <div class="profiler-kv-row">
            <span class="profiler-text--sm">Class</span>
            <strong class="profiler-text--mono">{jobData.job_class}</strong>
          </div>
          <div class="profiler-kv-row">
            <span class="profiler-text--sm">Job ID</span>
            <span class="profiler-text--xs profiler-text--mono profiler-text--muted">{jobData.job_id}</span>
          </div>
          <div class="profiler-kv-row">
            <span class="profiler-text--sm">Queue</span>
            <span class="profiler-text--mono">{jobData.queue}</span>
          </div>
          <div class="profiler-kv-row">
            <span class="profiler-text--sm">Executions</span>
            <span>{jobData.executions}</span>
          </div>
          <div class="profiler-kv-row">
            <span class="profiler-text--sm">Status</span>
            <span class={`badge-${isSuccess ? 'success' : 'error'}`}>
              {isSuccess ? '✓ Completed' : '✗ Failed'}
            </span>
          </div>
        </div>

        {jobData.arguments && jobData.arguments.length > 0 && (
          <div class="profiler-panel profiler-panel--sm">
            <h3 class="profiler-text--sm profiler-text--muted profiler-text--uppercase profiler-mb-3">Arguments</h3>
            {jobData.arguments.map((arg, i) => (
              <div key={i} class="profiler-kv-row">
                <span class="profiler-text--xs profiler-text--muted">[{i}]</span>
                <span class="profiler-text--xs profiler-text--mono" style="word-break:break-all">{String(arg)}</span>
              </div>
            ))}
          </div>
        )}
      </div>

      {jobData.error && (
        <div class="profiler-panel profiler-panel--sm profiler-mb-4" style="border-left: 3px solid var(--profiler-error, #ef4444)">
          <h3 class="profiler-text--sm profiler-text--muted profiler-text--uppercase profiler-mb-2">Error</h3>
          <pre class="profiler-code profiler-text--xs" style="white-space:pre-wrap;word-break:break-all;margin:0">{jobData.error}</pre>
        </div>
      )}
    </>
  )
}
