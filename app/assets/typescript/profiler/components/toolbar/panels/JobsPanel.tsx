import { ChildJobSummary } from '../../../dashboard/types'

interface Props {
  jobs: ChildJobSummary[]
}

function JobStatus({ job }: { job: ChildJobSummary }) {
  // A running job has no duration yet: its 0 would read as an instant success.
  if (job.status === 'running') {
    return (
      <strong class="profiler-text--xs profiler-text--mono profiler-text--info">
        <span class="profiler-spinner" aria-hidden="true">◐</span> running
      </strong>
    )
  }
  const failed = job.status === 'failed'
  return (
    <strong class={`profiler-text--xs profiler-text--mono ${failed ? 'profiler-text--error' : 'profiler-text--success'}`}>
      {failed ? '✗' : '✓'} {job.duration?.toFixed(0)}ms
    </strong>
  )
}

export function JobsPanel({ jobs }: Props) {
  const running = jobs.filter(j => j.status === 'running').length
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
        {running > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span>Running</span>
            <strong class="profiler-text--info">{running}</strong>
          </div>
        )}
        <div class="profiler-toolbar-panel-row">
          <span>Completed</span>
          <strong class={completed > 0 ? 'profiler-text--success' : 'profiler-text--muted'}>{completed}</strong>
        </div>
        <div class="profiler-toolbar-panel-row">
          <span>Failed</span>
          <strong class={failed > 0 ? 'profiler-text--error' : 'profiler-text--muted'}>{failed}</strong>
        </div>

        <div class="profiler-section__header profiler-mt-3">Last jobs</div>
        {preview.map((job, i) => (
          <div key={i} class="profiler-toolbar-panel-row">
            <span class="profiler-text--xs profiler-text--mono">{job.job_class}</span>
            <JobStatus job={job} />
          </div>
        ))}
        {remaining > 0 && (
          <div class="profiler-more">+ {remaining} more</div>
        )}
      </div>
    </>
  )
}
