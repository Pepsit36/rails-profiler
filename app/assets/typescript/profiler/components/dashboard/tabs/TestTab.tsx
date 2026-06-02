import { TestData } from '../../../dashboard/types'

interface Props {
  testData: TestData
}

function statusBadge(status: string) {
  if (status === 'passed')  return <span class="badge-success">✓ Passed</span>
  if (status === 'failed')  return <span class="badge-error">✗ Failed</span>
  if (status === 'pending') return <span class="badge-warning">⏸ Pending</span>
  return <span class="badge-default">{status}</span>
}

export function TestTab({ testData }: Props) {
  return (
    <div>
      <table class="profiler-detail-table">
        <tbody>
          <tr>
            <th>Test Name</th>
            <td style="word-break: break-word">{testData.test_name}</td>
          </tr>
          <tr>
            <th>Status</th>
            <td>{statusBadge(testData.status)}</td>
          </tr>
          <tr>
            <th>File</th>
            <td class="profiler-text--mono profiler-text--xs">{testData.test_file}:{testData.test_line}</td>
          </tr>
          <tr>
            <th>Framework</th>
            <td class="profiler-text--mono profiler-text--xs">{testData.framework}</td>
          </tr>
          {testData.assertions != null && (
            <tr>
              <th>Assertions</th>
              <td>{testData.assertions}</td>
            </tr>
          )}
          {testData.skip_reason && (
            <tr>
              <th>Skip reason</th>
              <td class="profiler-text--xs profiler-text--muted">{testData.skip_reason}</td>
            </tr>
          )}
          {testData.exception_message && (
            <tr>
              <th>Exception</th>
              <td>
                <pre class="profiler-text--xs" style="white-space: pre-wrap; color: var(--profiler-error, #ef4444)">
                  {testData.exception_message}
                </pre>
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  )
}
