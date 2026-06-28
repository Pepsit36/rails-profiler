import { useState, useEffect, useCallback } from 'preact/hooks'
import { useGetTestRunnerFiles, useCreateTestRun, useDeleteTestRun } from '../../generated/api'
import { TestRunTree, TestRun } from '../../dashboard/types'
import { TestFileTree } from './TestFileTree'
import { RunOutput } from './RunOutput'

const BASE = '/_profiler'

export function TestRunnerContent() {
  const [framework, setFramework] = useState<string>('')
  const [selected, setSelected] = useState<Set<string>>(new Set())
  const [currentRun, setCurrentRun] = useState<TestRun | null>(null)
  const [isRunning, setIsRunning] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const { data: filesData, isLoading: loading, refetch: refetchFiles } = useGetTestRunnerFiles(
    framework ? { framework } : {},
    { query: { refetchOnWindowFocus: false } } as any
  )
  const { mutateAsync: startTestRun } = useCreateTestRun()
  const { mutateAsync: killTestRun } = useDeleteTestRun()

  const frameworks: string[] = filesData?.frameworks ?? []
  const tree: TestRunTree[] = (filesData?.tree ?? []) as TestRunTree[]

  useEffect(() => {
    if (!framework && frameworks.length > 0) {
      setFramework(frameworks[0])
    }
  }, [frameworks])

  const loadFiles = useCallback((fw: string) => {
    setSelected(new Set())
    refetchFiles()
  }, [refetchFiles])

  // Stream output via SSE while run is active
  useEffect(() => {
    if (!currentRun || !isRunning) return
    if (['passed', 'failed', 'killed', 'error'].includes(currentRun.status)) {
      setIsRunning(false)
      return
    }

    const es = new EventSource(`${BASE}/api/test_runner/runs/${currentRun.id}/stream`)

    es.addEventListener('output', (e: MessageEvent) => {
      try {
        const data = JSON.parse(e.data)
        setCurrentRun(prev => prev ? { ...prev, output: (prev.output || '') + data.chunk } : prev)
      } catch {}
    })

    es.addEventListener('done', (e: MessageEvent) => {
      try {
        const data = JSON.parse(e.data)
        setCurrentRun(prev => prev ? { ...prev, status: data.status } : prev)
      } catch {}
      setIsRunning(false)
      es.close()
    })

    es.onerror = () => {
      es.close()
      // Fall back to one final poll to get the terminal state
      fetch(`${BASE}/api/test_runner/runs/${currentRun.id}`)
        .then(r => r.json())
        .then((data: TestRun) => { setCurrentRun(data); setIsRunning(false) })
        .catch(() => setIsRunning(false))
    }

    return () => es.close()
  }, [currentRun?.id, isRunning])

  const handleFrameworkChange = (fw: string) => {
    setFramework(fw)
    loadFiles(fw)
  }

  const toggleFile = (path: string) => {
    setSelected(prev => {
      const next = new Set(prev)
      next.has(path) ? next.delete(path) : next.add(path)
      return next
    })
  }

  const toggleDir = (_dir: string, paths: string[]) => {
    setSelected(prev => {
      const next = new Set(prev)
      const allSelected = paths.every(p => next.has(p))
      if (allSelected) {
        paths.forEach(p => next.delete(p))
      } else {
        paths.forEach(p => next.add(p))
      }
      return next
    })
  }

  const selectAll = () => {
    const all = tree.flatMap(d => d.files.map(f => f.path))
    setSelected(new Set(all))
  }

  const selectNone = () => setSelected(new Set())

  const runTests = async () => {
    if (selected.size === 0 || isRunning) return
    setError(null)
    try {
      const data = await startTestRun({ data: { files: Array.from(selected), framework } }) as TestRun
      setCurrentRun(data)
      setIsRunning(true)
    } catch {
      setError('Failed to start test run')
    }
  }

  const stopRun = async () => {
    if (!currentRun) return
    try {
      await killTestRun({ id: currentRun.id })
      setIsRunning(false)
      setCurrentRun(prev => prev ? { ...prev, status: 'killed' } : prev)
    } catch {}
  }

  const totalFiles = tree.reduce((n, d) => n + d.files.length, 0)

  return (
    <div>
      {error && (
        <div style="color: var(--profiler-error, #ef4444); background: rgba(239,68,68,0.1); border: 1px solid var(--profiler-error, #ef4444); border-radius: 4px; padding: 8px 12px; margin-bottom: 12px; font-size: 13px">
          {error}
        </div>
      )}

      <div class="profiler-action-bar profiler-mb-3">
        <div class="profiler-filter-group">
          {frameworks.length > 0 && frameworks.map(fw => (
            <button
              key={fw}
              class={`profiler-preset-btn${framework === fw ? ' profiler-preset-btn--active' : ''}`}
              onClick={() => handleFrameworkChange(fw)}
              disabled={isRunning}
            >
              {fw === 'rspec' ? 'RSpec' : 'Minitest'}
            </button>
          ))}
        </div>
        <div class="profiler-filter-group" style="margin-left: auto">
          <span class="profiler-text--xs profiler-text--muted">
            {selected.size} / {totalFiles} selected
          </span>
          <button class="btn btn-secondary btn-sm" onClick={selectAll} disabled={isRunning || loading}>All</button>
          <button class="btn btn-secondary btn-sm" onClick={selectNone} disabled={isRunning}>None</button>
          {isRunning ? (
            <button class="btn btn-danger btn-sm" onClick={stopRun}>■ Stop</button>
          ) : (
            <button
              class="btn btn-sm"
              style="background: var(--profiler-accent, #06b6d4); color: #000; font-weight: 600"
              onClick={runTests}
              disabled={selected.size === 0}
            >
              ▶ Run Selected ({selected.size})
            </button>
          )}
        </div>
      </div>

      <div style="display: grid; grid-template-columns: 260px 1fr; height: 460px; border: 1px solid var(--profiler-border, rgba(255,255,255,0.1)); border-radius: 6px; overflow: hidden">
        <div style="border-right: 1px solid var(--profiler-border, rgba(255,255,255,0.1)); overflow-y: auto; padding: 8px">
          {loading ? (
            <div class="profiler-text--xs profiler-text--muted" style="padding: 8px">Loading files…</div>
          ) : tree.length === 0 ? (
            <div class="profiler-text--xs profiler-text--muted" style="padding: 8px">
              No {framework} test files found
            </div>
          ) : (
            <TestFileTree
              tree={tree}
              selected={selected}
              onToggleFile={toggleFile}
              onToggleDir={toggleDir}
            />
          )}
        </div>

        <div style="overflow: hidden; display: flex; flex-direction: column">
          <RunOutput run={currentRun} />
        </div>
      </div>
    </div>
  )
}
