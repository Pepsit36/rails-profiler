import { ExceptionData, BacktraceFrame } from '../../../dashboard/types'

interface Props {
  exceptionData: ExceptionData
}

export function ExceptionPanel({ exceptionData }: Props) {
  const firstAppFrame = exceptionData.backtrace?.find((f: BacktraceFrame) => f.app_frame)

  return (
    <>
      <div class="profiler-toolbar-panel-header" style="color:var(--profiler-error,#ef4444);">
        💥 {exceptionData.exception_class}
      </div>
      <div class="profiler-toolbar-panel-content">
        <div class="profiler-toolbar-panel-row" style="flex-direction:column;align-items:flex-start;gap:4px;">
          <span class="profiler-text--xs" style="max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
            {exceptionData.message}
          </span>
          {firstAppFrame && (
            <span class="profiler-text--xs profiler-text--muted" style="max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">
              {firstAppFrame.location}
            </span>
          )}
        </div>
      </div>
    </>
  )
}
