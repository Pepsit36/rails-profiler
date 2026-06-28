import { useState } from 'preact/hooks'
import { TestRunTree } from '../../dashboard/types'

interface Props {
  tree: TestRunTree[]
  selected: Set<string>
  onToggleFile: (path: string) => void
  onToggleDir: (dir: string, paths: string[]) => void
}

export function TestFileTree({ tree, selected, onToggleFile, onToggleDir }: Props) {
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())

  const toggleCollapse = (dir: string) => {
    setCollapsed(prev => {
      const next = new Set(prev)
      next.has(dir) ? next.delete(dir) : next.add(dir)
      return next
    })
  }

  const dirSelected = (paths: string[]): 'all' | 'none' | 'partial' => {
    const count = paths.filter(p => selected.has(p)).length
    if (count === 0) return 'none'
    if (count === paths.length) return 'all'
    return 'partial'
  }

  return (
    <div class="profiler-text--xs profiler-text--mono" style="overflow-y: auto; height: 100%">
      {tree.map(({ directory, files }) => {
        const paths = files.map(f => f.path)
        const sel = dirSelected(paths)
        const isCollapsed = collapsed.has(directory)

        return (
          <div key={directory} style="margin-bottom: 4px">
            <div
              style="display: flex; align-items: center; gap: 6px; padding: 3px 6px; cursor: pointer; border-radius: 4px; background: var(--profiler-bg-secondary, rgba(255,255,255,0.05))"
              onClick={() => toggleCollapse(directory)}
            >
              <input
                type="checkbox"
                checked={sel === 'all'}
                ref={(el: HTMLInputElement | null) => { if (el) el.indeterminate = sel === 'partial' }}
                onClick={(e: MouseEvent) => {
                  e.stopPropagation()
                  onToggleDir(directory, paths)
                }}
                style="cursor: pointer; flex-shrink: 0"
              />
              <span style="color: var(--profiler-text-muted, #888); flex-shrink: 0">{isCollapsed ? '▶' : '▼'}</span>
              <span style="color: var(--profiler-accent, #06b6d4); font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap" title={directory}>
                {directory}/
              </span>
              <span style="color: var(--profiler-text-muted, #888); margin-left: auto; flex-shrink: 0">({files.length})</span>
            </div>

            {!isCollapsed && files.map(file => (
              <div
                key={file.path}
                style="display: flex; align-items: center; gap: 6px; padding: 2px 6px 2px 24px; cursor: pointer; border-radius: 4px"
                onClick={() => onToggleFile(file.path)}
              >
                <input
                  type="checkbox"
                  checked={selected.has(file.path)}
                  onClick={(e: MouseEvent) => { e.stopPropagation(); onToggleFile(file.path) }}
                  style="cursor: pointer; flex-shrink: 0"
                />
                <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--profiler-text, #e2e8f0)" title={file.path}>
                  {file.name}
                </span>
              </div>
            ))}
          </div>
        )
      })}
    </div>
  )
}
