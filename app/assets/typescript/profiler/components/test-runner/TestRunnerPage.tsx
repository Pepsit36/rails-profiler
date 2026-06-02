import { TestRunnerContent } from './TestRunnerContent'

const BASE = '/_profiler'

export function TestRunnerPage() {
  return (
    <div class="container">
      <div class="header">
        <h1>
          <a href={BASE}><span class="h1-emoji">🔍</span></a>
          {' '}<span class="h1-emoji">🧪</span> Test Runner
        </h1>
        <p>Run tests from the profiler and capture a performance profile for each test.</p>
      </div>

      <div class="profiler-panel profiler-mb-6">
        <div class="profiler-p-4">
          <TestRunnerContent />
        </div>
      </div>
    </div>
  )
}
