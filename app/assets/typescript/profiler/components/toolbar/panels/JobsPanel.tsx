import { ChildJobSummary } from '../../../dashboard/types'

interface Props {
  jobs: ChildJobSummary[]
}

export function JobsPanel({ jobs }: Props) {
  const completed = jobs.filter(j => j.status === 'completed').length
  const failed = jobs.filter(j => j.status === 'failed').length
  const preview = jobs.slice(0, 5)
  const remaining = jobs.length - 5

  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Background Jobs
        <span class="profiler-float-right">{jobs.length} job{jobs.length !== 1 ? 's' : ''}</span>
      </div>
      <div class="profiler-toolbar-panel-content">
        <div class="profiler-section__header">Summary</div>
        <div class="profiler-toolbar-panel-row">
          <span>Completed</span>
          <strong class="profiler-text--success">{completed}</strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Failed</span>
          <strong class={failed > 0 ? 'profiler-text--error' : 'profiler-text--muted'}>{failed}</strong>
        </div>

        <div class="profiler-section__header profiler-mt-3">Last jobs</div>
        {preview.map((job, i) => (
          <div key={i} class="profiler-toolbar-panel-row">
            <span class="profiler-text--xs profiler-text--mono">{job.job_class}</span>
            <strong class={`profiler-text--xs profiler-text--mono ${job.status === 'failed' ? 'profiler-text--error' : 'profiler-text--success'}`}>
              {job.status === 'failed' ? '✗' : '✓'} {job.duration?.toFixed(0)}ms
            </strong>
          </div>
        ))}
        {remaining > 0 && (
          <div class="profiler-more">+ {remaining} more</div>
        )}
      </div>
    </>
  )
}
