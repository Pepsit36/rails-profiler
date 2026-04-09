import { ChildJobSummary } from '../../../dashboard/types'

interface Props {
  jobs: ChildJobSummary[]
}

export function JobsTab({ jobs }: Props) {
  if (!jobs?.length) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">⚙️</div>
        <h3 class="profiler-empty__title">No jobs triggered</h3>
        <p class="profiler-empty__description">Background jobs enqueued during this request will appear here.</p>
      </div>
    )
  }

  return (
    <>
      <h2 class="profiler-section__header">Background Jobs ({jobs.length})</h2>

      {jobs.map((job, index) => (
        <div key={index} class={`profiler-ajax-card profiler-ajax-card--${job.status === 'completed' ? 'success' : job.status === 'failed' ? 'error' : 'default'}`}>
          <div class="profiler-ajax-card__row">
            <div class="profiler-flex profiler-flex--gap-3">
              <span class={`badge-${job.status === 'completed' ? 'success' : job.status === 'failed' ? 'error' : 'warning'}`}>
                {job.status ?? 'unknown'}
              </span>
              <strong class="profiler-ajax-card__path">{job.job_class}</strong>
            </div>
            <span class={job.duration >= 1000 ? 'badge-error' : job.duration >= 200 ? 'badge-warning' : 'badge-success'}>
              {job.duration?.toFixed(2)} ms
            </span>
          </div>
          <div class="profiler-ajax-card__row">
            <span class="profiler-ajax-card__time profiler-text--muted">
              {job.queue && <span>Queue: <strong>{job.queue}</strong> · </span>}
              {new Date(job.started_at).toLocaleTimeString('en', { hour12: false })}
            </span>
            <a href={`/_profiler/profiles/${job.token}`} class="profiler-text--sm" style="color: var(--profiler-accent);">
              View Job →
            </a>
          </div>
        </div>
      ))}
    </>
  )
}
