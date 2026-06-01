interface ConsoleData {
  expression: string
  return_value?: string
}

interface Props {
  data: ConsoleData
}

export function ConsoleTab({ data }: Props) {
  return (
    <div class="profiler-p-4">
      <div class="profiler-mb-6">
        <h3 class="profiler-section-title profiler-mb-2">Expression</h3>
        <pre class="profiler-code-block profiler-code-block--full">{data.expression}</pre>
      </div>
      {data.return_value !== undefined && (
        <div>
          <h3 class="profiler-section-title profiler-mb-2">Return value</h3>
          <pre class="profiler-code-block profiler-code-block--full">{data.return_value}</pre>
        </div>
      )}
    </div>
  )
}
