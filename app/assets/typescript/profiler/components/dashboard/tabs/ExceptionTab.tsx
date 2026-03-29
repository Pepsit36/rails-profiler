import { useState } from 'preact/hooks'
import { ExceptionData, BacktraceFrame } from '../../../dashboard/types'

interface Props {
  exceptionData: ExceptionData | undefined
}

export function ExceptionTab({ exceptionData }: Props) {
  const [showAllFrames, setShowAllFrames] = useState(false)

  if (!exceptionData?.exception_class) {
    return (
      <div class="profiler-empty">
        <div class="profiler-empty__icon">💥</div>
        <h3 class="profiler-empty__title">No exception recorded</h3>
        <div class="profiler-empty__description">
          <p>Exceptions raised during this request will appear here.</p>
        </div>
      </div>
    )
  }

  const backtrace = exceptionData.backtrace || []
  const appFrames = backtrace.filter((f: BacktraceFrame) => f.app_frame)
  const displayFrames = showAllFrames ? backtrace : backtrace.slice(0, 30)

  return (
    <>
      <div class="profiler-mb-4" style="padding: 12px 16px; background: color-mix(in srgb, var(--profiler-error, #ef4444) 10%, transparent); border-left: 4px solid var(--profiler-error, #ef4444); border-radius: 4px;">
        <div class="profiler-text--error" style="font-size:1.1em;font-weight:700;margin-bottom:4px;">
          {exceptionData.exception_class}
        </div>
        <div style="font-family:monospace;font-size:0.9em;word-break:break-word;">
          {exceptionData.message}
        </div>
      </div>

      {appFrames.length > 0 && (
        <div class="profiler-mb-4">
          <h3 class="profiler-section__header">Application frames ({appFrames.length})</h3>
          {appFrames.map((frame: BacktraceFrame, i: number) => (
            <div key={i} class="profiler-query-card profiler-mb-1">
              <code class="profiler-text--sm">{frame.location}</code>
            </div>
          ))}
        </div>
      )}

      <div>
        <h3 class="profiler-section__header">
          Full backtrace ({backtrace.length} frames)
        </h3>
        {displayFrames.map((frame: BacktraceFrame, i: number) => (
          <div
            key={i}
            class="profiler-query-card profiler-mb-1"
            style={frame.app_frame ? '' : 'opacity:0.45;'}
          >
            <code class={`profiler-text--sm${frame.app_frame ? ' profiler-text--success' : ' profiler-text--muted'}`}>
              {frame.location}
            </code>
          </div>
        ))}
        {!showAllFrames && backtrace.length > 30 && (
          <button
            class="btn btn-secondary btn-sm profiler-mt-2"
            onClick={() => setShowAllFrames(true)}
          >
            Show all {backtrace.length} frames
          </button>
        )}
      </div>
    </>
  )
}
