import { useListProfiles } from '../../../generated/api'
import { Profile } from '../../../dashboard/types'
import { methodBadge, statusBadge } from './shared/utils'

interface Props {
  profile: Profile
}

export function TraceTab({ profile }: Props) {
  if (!profile.trace_id) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">🔗</div>
        <h3 class="profiler-empty__title">No trace for this profile</h3>
        <p class="profiler-empty__description">This profile was saved before distributed tracing was available.</p>
      </div>
    )
  }

  return <TraceBody profile={profile} traceId={profile.trace_id} />
}

function TraceBody({ profile, traceId }: Props & { traceId: string }) {
  const { data, isLoading, isError } = useListProfiles({ trace_id: traceId, limit: 50 })
  const others = (data?.profiles ?? []).filter(p => p.token !== profile.token)

  return (
    <>
      <h2 class="profiler-section__header">Trace</h2>
      <div class="profiler-panel profiler-panel--sm profiler-mb-6">
        <div class="profiler-kv-row">
          <span>Trace ID</span>
          <code class="profiler-code">{traceId}</code>
        </div>
        <div class="profiler-kv-row">
          <span>Span ID</span>
          <code class="profiler-code">{profile.span_id ?? '-'}</code>
        </div>
        <div class="profiler-kv-row">
          <span>Parent span ID</span>
          {profile.parent_span_id
            ? <code class="profiler-code">{profile.parent_span_id}</code>
            : <span class="profiler-text--muted">none, this request started the trace</span>}
        </div>
      </div>

      <h3 class="profiler-text--lg profiler-mb-3">Other profiles in this trace</h3>
      {isLoading && <p class="profiler-text--muted">Loading...</p>}
      {isError && <p class="profiler-text--muted">Could not load the profiles of this trace.</p>}
      {!isLoading && !isError && others.length === 0 && (
        <div class="profiler-empty">
          <div class="profiler-empty__icon">🔗</div>
          <h3 class="profiler-empty__title">Single-span trace</h3>
          <p class="profiler-empty__description">
            No other stored profile shares this trace id. The request had no traceparent from a caller,
            or the other services are not profiled here.
          </p>
        </div>
      )}
      {others.map(p => (
        <div key={p.token} class="profiler-ajax-card">
          <div class="profiler-ajax-card__row">
            <div class="profiler-flex profiler-flex--gap-3">
              <span class={`profiler-ajax-card__method badge-${methodBadge(p.method ?? '')}`}>{p.method}</span>
              <strong class="profiler-ajax-card__path">{p.path}</strong>
            </div>
            <div class="profiler-flex profiler-flex--gap-2">
              <span class={`badge-${statusBadge(p.status ?? 0)}`}>{p.status}</span>
              {p.span_id && p.span_id === profile.parent_span_id && <span class="badge-info">caller</span>}
            </div>
          </div>
          <div class="profiler-ajax-card__row">
            <span class="profiler-ajax-card__time">span {p.span_id ?? '-'}</span>
            <a href={`/_profiler/profiles/${p.token}`} class="profiler-text--sm" style="color: var(--profiler-accent);">
              View Profile →
            </a>
          </div>
        </div>
      ))}
    </>
  )
}
