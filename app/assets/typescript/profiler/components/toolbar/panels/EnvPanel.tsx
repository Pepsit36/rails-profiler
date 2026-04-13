import { EnvData } from '../../../dashboard/types'

interface Props {
  envData: EnvData
}

export function EnvPanel({ envData }: Props) {
  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Environment
      </div>
      <div class="profiler-toolbar-panel-content">
        <div class="profiler-toolbar-panel-row">
          <span>Variables</span>
          <strong>{envData.total}</strong>
        </div>
      </div>
    </>
  )
}
