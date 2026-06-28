import { useRef, useEffect, useState } from 'preact/hooks'
import { useUpdateFunctionProfiling } from '../../../generated/api'
import type { FlameGraphData, FlameGraphNode, FlameGraphCategory, PerformanceData, FunctionProfileData, FunctionStat } from '../../../dashboard/types'
import { FlameGraphRenderer, FlatFrame } from '../../../flamegraph/FlameGraphRenderer'
import { FlameGraphTooltip } from '../../../flamegraph/FlameGraphTooltip'
import { FlameGraphBreadcrumbs } from '../../../flamegraph/FlameGraphBreadcrumbs'
import { formatBytes } from './shared/utils'

const CATEGORY_COLORS: Record<FlameGraphCategory, string> = {
  controller: '#60a5fa',
  view: '#34d399',
  partial: '#f59e0b',
  sql: '#fb923c',
  cache: '#a78bfa',
  http: '#f87171',
  custom: '#e879f9',
  method: '#94a3b8'
}

const CATEGORY_LABELS: Record<FlameGraphCategory, string> = {
  controller: 'Controller',
  view: 'View',
  partial: 'Partial',
  sql: 'SQL',
  cache: 'Cache',
  http: 'HTTP',
  custom: 'Custom',
  method: 'Method'
}

type SortKey = 'total_duration' | 'self_duration' | 'memory_bytes' | 'allocated_objects' | 'calls'
type SortDir = 'asc' | 'desc'

interface Props {
  flamegraphData: FlameGraphData | undefined
  perfData: PerformanceData | undefined
  functionProfileData: FunctionProfileData | undefined
}

export function FlameGraphTab({ flamegraphData, perfData, functionProfileData }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const rendererRef = useRef<FlameGraphRenderer | null>(null)
  const tooltipRef = useRef<FlameGraphTooltip | null>(null)
  const breadcrumbsRef = useRef<FlameGraphBreadcrumbs | null>(null)
  const searchInputRef = useRef<HTMLInputElement>(null)
  const [isZoomed, setIsZoomed] = useState(false)
  const [searchQuery, setSearchQuery] = useState('')
  const [matchCount, setMatchCount] = useState(0)
  const [totalCount, setTotalCount] = useState(0)
  const [fnSortKey, setFnSortKey] = useState<SortKey>('total_duration')
  const [fnSortDir, setFnSortDir] = useState<SortDir>('desc')
  const [fnEnabled, setFnEnabled] = useState<boolean>(functionProfileData?.enabled ?? false)
  const [fnMaxFrames, setFnMaxFrames] = useState<number>(functionProfileData?.max_frames ?? 2000)
  const [fnMode, setFnMode] = useState<'full' | 'lite'>(functionProfileData?.mode === 'lite' ? 'lite' : 'full')
  const [fnClock, setFnClock] = useState<'wall' | 'cpu' | 'object'>(functionProfileData?.clock ?? 'wall')
  const [fnToggling, setFnToggling] = useState(false)
  const [fnMaxFramesUpdating, setFnMaxFramesUpdating] = useState(false)
  const [fnModeUpdating, setFnModeUpdating] = useState(false)
  const [fnClockUpdating, setFnClockUpdating] = useState(false)

  const { mutateAsync: patchFunctionProfiling } = useUpdateFunctionProfiling()

  const toggleFunctionProfiling = async () => {
    setFnToggling(true)
    try {
      const json = await patchFunctionProfiling({ data: { enabled: !fnEnabled } })
      setFnEnabled(json.enabled)
    } finally {
      setFnToggling(false)
    }
  }

  const updateMaxFrames = async (value: number) => {
    setFnMaxFramesUpdating(true)
    try {
      const json = await patchFunctionProfiling({ data: { max_frames: value } })
      setFnMaxFrames(json.max_frames)
    } finally {
      setFnMaxFramesUpdating(false)
    }
  }

  const updateMode = async (value: 'full' | 'lite') => {
    setFnMode(value)
    setFnModeUpdating(true)
    try {
      const json = await patchFunctionProfiling({ data: { mode: value } })
      setFnMode(json.mode ?? value)
    } finally {
      setFnModeUpdating(false)
    }
  }

  const updateClock = async (value: 'wall' | 'cpu' | 'object') => {
    setFnClockUpdating(true)
    try {
      const json = await patchFunctionProfiling({ data: { clock: value } })
      setFnClock(json.clock ?? value)
    } finally {
      setFnClockUpdating(false)
    }
  }

  const data = flamegraphData

  useEffect(() => {
    if (!data?.root_events?.length || !canvasRef.current || !containerRef.current) return

    const container = containerRef.current
    const canvas = canvasRef.current

    const tooltip = new FlameGraphTooltip(container, data.total_duration)
    tooltipRef.current = tooltip

    const breadcrumbs = new FlameGraphBreadcrumbs(container, (node: FlameGraphNode | null) => {
      if (!rendererRef.current) return
      if (node) {
        rendererRef.current.zoomTo(node)
      } else {
        rendererRef.current.resetZoom()
      }
    })
    breadcrumbsRef.current = breadcrumbs

    // Insert breadcrumbs before canvas
    container.insertBefore(breadcrumbs['el'], canvas)

    const renderer = new FlameGraphRenderer(canvas, data.root_events, {
      onHover: (frame: FlatFrame | null, x: number, y: number) => {
        if (frame) {
          tooltip.show(frame, x, y)
        } else {
          tooltip.hide()
        }
      },
      onClick: (_frame: FlatFrame) => {
        setIsZoomed(true)
      },
      onZoomChange: (ancestors: FlameGraphNode[]) => {
        breadcrumbs.update(ancestors)
        setIsZoomed(ancestors.length > 0)
      },
      onSearchResults: (match: number, total: number) => {
        setMatchCount(match)
        setTotalCount(total)
      }
    })
    rendererRef.current = renderer

    const handleResize = () => renderer.resizeCanvas()
    window.addEventListener('resize', handleResize)

    const handleTheme = () => renderer.render()
    document.addEventListener('profiler:theme-change', handleTheme)

    return () => {
      renderer.destroy()
      tooltip.destroy()
      breadcrumbs.destroy()
      window.removeEventListener('resize', handleResize)
      document.removeEventListener('profiler:theme-change', handleTheme)
      rendererRef.current = null
      tooltipRef.current = null
      breadcrumbsRef.current = null
    }
  }, [data])

  // Propagate search query to renderer
  useEffect(() => {
    rendererRef.current?.setSearchQuery(searchQuery)
    if (!searchQuery) {
      setMatchCount(0)
      setTotalCount(0)
    }
  }, [searchQuery])

  // Ctrl+F / Cmd+F focuses the search input
  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'f') {
        e.preventDefault()
        searchInputRef.current?.focus()
      }
    }
    document.addEventListener('keydown', onKeyDown, { capture: true })
    return () => document.removeEventListener('keydown', onKeyDown, { capture: true })
  }, [])

  // Fallback to old performance cards if no flamegraph data
  if (!data?.root_events?.length) {
    if (!perfData?.events?.length) {
      return (
        <div class="profiler-flamegraph">
          <div class="profiler-empty">
            <p class="profiler-empty__description">No performance events recorded</p>
          </div>
          <FunctionProfilingSection
            data={functionProfileData}
            enabled={fnEnabled}
            toggling={fnToggling}
            maxFrames={fnMaxFrames}
            maxFramesUpdating={fnMaxFramesUpdating}
            mode={fnMode}
            modeUpdating={fnModeUpdating}
            clock={fnClock}
            clockUpdating={fnClockUpdating}
            sortKey={fnSortKey}
            sortDir={fnSortDir}
            onToggle={toggleFunctionProfiling}
            onMaxFramesChange={updateMaxFrames}
            onModeChange={updateMode}
            onClockChange={updateClock}
            onSortChange={(key, dir) => { setFnSortKey(key); setFnSortDir(dir) }}
          />
        </div>
      )
    }

    return (
      <div class="profiler-flamegraph">
        <h2 class="profiler-section__header">
          Performance Timeline ({perfData.total_events} events)
        </h2>
        <p class="profiler-mb-4">Total Duration: <strong>{perfData.total_duration} ms</strong></p>
        {perfData.events.map((event, index) => (
          <div key={index} class="profiler-query-card">
            <div class="profiler-query-card__header">
              <strong>{event.name}</strong>
              <span class={event.duration >= 500 ? 'badge-error' : event.duration >= 100 ? 'badge-warning' : 'badge-success'}>{event.duration.toFixed(2)} ms</span>
            </div>
            {event.payload && Object.keys(event.payload).length > 0 && (
              <pre class="profiler-text--xs profiler-text--muted profiler-mt-2">
                {JSON.stringify(event.payload, null, 2)}
              </pre>
            )}
          </div>
        ))}
        <FunctionProfilingSection
          data={functionProfileData}
          enabled={fnEnabled}
          toggling={fnToggling}
          maxFrames={fnMaxFrames}
          maxFramesUpdating={fnMaxFramesUpdating}
          mode={fnMode}
          modeUpdating={fnModeUpdating}
          clock={fnClock}
          clockUpdating={fnClockUpdating}
          sortKey={fnSortKey}
          sortDir={fnSortDir}
          onToggle={toggleFunctionProfiling}
          onMaxFramesChange={updateMaxFrames}
          onModeChange={updateMode}
          onClockChange={updateClock}
          onSortChange={(key, dir) => { setFnSortKey(key); setFnSortDir(dir) }}
        />
      </div>
    )
  }

  // Count events by category
  const categoryCounts: Partial<Record<FlameGraphCategory, { count: number; duration: number }>> = {}
  const countNode = (node: FlameGraphNode) => {
    const cat = node.category as FlameGraphCategory
    if (!categoryCounts[cat]) categoryCounts[cat] = { count: 0, duration: 0 }
    categoryCounts[cat]!.count++
    categoryCounts[cat]!.duration += node.duration
    node.children?.forEach(countNode)
  }
  data.root_events.forEach(countNode)

  const handleReset = () => {
    rendererRef.current?.resetZoom()
    setIsZoomed(false)
  }

  return (
    <div class="profiler-flamegraph">
      {/* Stats bar */}
      <div class="profiler-flamegraph__stats">
        <div class="stat-item">
          <span class="stat-label">Total Events</span>
          <span class="stat-value">{data.total_events}</span>
        </div>
        <div class="stat-item">
          <span class="stat-label">Total Duration</span>
          <span class="stat-value">{data.total_duration.toFixed(2)} <small>ms</small></span>
        </div>
        {(Object.keys(categoryCounts) as FlameGraphCategory[]).map(cat => (
          <div key={cat} class="stat-item">
            <span class="stat-label">
              <span class="stat-dot" style={{ background: CATEGORY_COLORS[cat] }} />
              {CATEGORY_LABELS[cat]}
            </span>
            <span class="stat-value">{categoryCounts[cat]!.count}</span>
          </div>
        ))}
      </div>

      {/* Legend */}
      <div class="profiler-flamegraph__legend">
        {(Object.keys(CATEGORY_COLORS) as FlameGraphCategory[]).map(cat => (
          <div key={cat} class="legend-item">
            <span class="legend-color" style={{ background: CATEGORY_COLORS[cat] }} />
            <span>{CATEGORY_LABELS[cat]}</span>
          </div>
        ))}
      </div>

      {/* Controls */}
      <div class="profiler-flamegraph__controls">
        {isZoomed && (
          <button class="profiler-flamegraph__reset" onClick={handleReset}>
            Reset Zoom
          </button>
        )}
        <div class="profiler-flamegraph__search">
          <input
            ref={searchInputRef}
            type="text"
            class="profiler-flamegraph__search-input"
            placeholder="Search events… (Ctrl+F)"
            value={searchQuery}
            onInput={e => setSearchQuery((e.target as HTMLInputElement).value)}
          />
          {searchQuery && (
            <span class="profiler-flamegraph__match-count">{matchCount} / {totalCount}</span>
          )}
        </div>
        <span class="profiler-flamegraph__hint">Click to zoom, scroll to zoom in/out, drag to pan</span>
      </div>

      {/* Canvas container */}
      <div class="profiler-flamegraph__canvas-container" ref={containerRef}>
        <canvas
          ref={canvasRef}
          class="profiler-flamegraph__canvas"
          style={{ width: '100%' }}
        />
      </div>

      <FunctionProfilingSection
        data={functionProfileData}
        enabled={fnEnabled}
        toggling={fnToggling}
        maxFrames={fnMaxFrames}
        maxFramesUpdating={fnMaxFramesUpdating}
        mode={fnMode}
        modeUpdating={fnModeUpdating}
        clock={fnClock}
        clockUpdating={fnClockUpdating}
        sortKey={fnSortKey}
        sortDir={fnSortDir}
        onToggle={toggleFunctionProfiling}
        onMaxFramesChange={updateMaxFrames}
        onModeChange={updateMode}
        onClockChange={updateClock}
        onSortChange={(key, dir) => { setFnSortKey(key); setFnSortDir(dir) }}
      />
    </div>
  )
}

interface FunctionProfilingSectionProps {
  data: FunctionProfileData | undefined
  enabled: boolean
  toggling: boolean
  maxFrames: number
  maxFramesUpdating: boolean
  mode: 'full' | 'lite'
  modeUpdating: boolean
  clock: 'wall' | 'cpu' | 'object'
  clockUpdating: boolean
  sortKey: SortKey
  sortDir: SortDir
  onToggle: () => void
  onMaxFramesChange: (value: number) => void
  onModeChange: (value: 'full' | 'lite') => void
  onClockChange: (value: 'wall' | 'cpu' | 'object') => void
  onSortChange: (key: SortKey, dir: SortDir) => void
}

function collectNames(node: FlameGraphNode, out: Set<string> = new Set()): Set<string> {
  out.add(node.name)
  node.children?.forEach(c => collectNames(c, out))
  return out
}

function findFirstNodeByName(nodes: FlameGraphNode[], name: string): FlameGraphNode | null {
  for (const node of nodes) {
    if (node.name === name) return node
    const found = findFirstNodeByName(node.children ?? [], name)
    if (found) return found
  }
  return null
}

function FunctionProfilingSection({ data, enabled, toggling, maxFrames, maxFramesUpdating, mode, modeUpdating, clock, clockUpdating, sortKey, sortDir, onToggle, onMaxFramesChange, onModeChange, onClockChange, onSortChange }: FunctionProfilingSectionProps) {
  const [filterNames, setFilterNames] = useState<Set<string> | null>(null)
  const [filterLabel, setFilterLabel] = useState<string | null>(null)
  const [hoveredFnName, setHoveredFnName] = useState<string | null>(null)
  const fnRendererRef = useRef<FlameGraphRenderer | null>(null)

  const hasData = enabled && data?.enabled && (data.functions?.length ?? 0) > 0
  const dataMode = data?.mode ?? 'full'
  const dataClock = data?.clock ?? 'wall'
  const isSampling = dataMode === 'lite'
  const isObjectClock = dataClock === 'object'
  const showAllocated = !isSampling
  const showMemory = dataMode === 'full'
  const showClock = mode === 'lite'  // show based on current setting, not last profiled data
  const effectiveSortKey: SortKey = (sortKey === 'memory_bytes' && !showMemory) || (sortKey === 'allocated_objects' && !showAllocated)
    ? 'total_duration'
    : sortKey
  const rootCalls = hasData ? (data!.root_calls ?? []) : []
  const sortedFunctions: FunctionStat[] = hasData
    ? [...(data!.functions!)].sort((a, b) =>
        sortDir === 'asc' ? a[effectiveSortKey] - b[effectiveSortKey] : b[effectiveSortKey] - a[effectiveSortKey]
      )
    : []
  const displayedFunctions = filterNames
    ? sortedFunctions.filter(fn => filterNames.has(fn.name))
    : sortedFunctions

  const handleFrameSelect = (node: FlameGraphNode | null) => {
    if (!node) {
      setFilterNames(null)
      setFilterLabel(null)
    } else {
      setFilterNames(collectNames(node))
      setFilterLabel(node.name)
    }
  }

  const handleColClick = (key: SortKey) => {
    if (key === sortKey) {
      onSortChange(key, sortDir === 'asc' ? 'desc' : 'asc')
    } else {
      onSortChange(key, 'desc')
    }
  }

  const sortIcon = (key: SortKey) => {
    if (effectiveSortKey !== key) return <span class="sort-icon sort-icon--idle">⇅</span>
    return <span class="sort-icon sort-icon--active">{sortDir === 'asc' ? '▲' : '▼'}</span>
  }

  const handleMaxFramesBlur = (e: FocusEvent) => {
    const value = parseInt((e.target as HTMLInputElement).value, 10)
    if (!isNaN(value) && value > 0 && value !== maxFrames) {
      onMaxFramesChange(value)
    }
  }

  const handleMaxFramesKeyDown = (e: KeyboardEvent) => {
    if (e.key === 'Enter') {
      (e.target as HTMLInputElement).blur()
    }
  }

  return (
    <div class="profiler-fn-profiling">
      <div class="profiler-fn-profiling__header">
        <span class={`profiler-fn-profiling__title${enabled ? ' profiler-fn-profiling__title--active' : ''}`}>
          Function Profiling
        </span>
        <div class="profiler-fn-profiling__controls">
          <div class="profiler-fn-profiling__mode-selector">
            {(['full', 'lite'] as const).map(m => (
              <button
                key={m}
                class={`profiler-fn-profiling__mode-btn${mode === m ? ' profiler-fn-profiling__mode-btn--active' : ''}`}
                onClick={() => mode !== m && onModeChange(m)}
                disabled={modeUpdating}
                title={m === 'full' ? 'Exhaustive TracePoint — timing + allocations + memory bytes' : 'StackProf sampling — very low overhead'}
              >
                {m.charAt(0).toUpperCase() + m.slice(1)}
              </button>
            ))}
          </div>
          {showClock && (
            <div class="profiler-fn-profiling__mode-selector">
              {(['wall', 'cpu', 'object'] as const).map(c => (
                <button
                  key={c}
                  class={`profiler-fn-profiling__mode-btn${clock === c ? ' profiler-fn-profiling__mode-btn--active' : ''}`}
                  onClick={() => clock !== c && onClockChange(c)}
                  disabled={clockUpdating}
                  title={c === 'wall' ? 'Wall-clock time (includes I/O waits)' : c === 'cpu' ? 'CPU time only (excludes I/O waits)' : 'Object allocations per function'}
                >
                  {c === 'wall' ? 'Wall' : c === 'cpu' ? 'CPU' : 'Alloc'}
                </button>
              ))}
            </div>
          )}
          <label class="profiler-fn-profiling__max-frames-label">
            Max frames
            <input
              type="number"
              class="profiler-fn-profiling__max-frames-input"
              defaultValue={maxFrames}
              min={1}
              disabled={maxFramesUpdating}
              onBlur={handleMaxFramesBlur}
              onKeyDown={handleMaxFramesKeyDown}
            />
            {maxFramesUpdating && <span class="profiler-fn-profiling__updating">…</span>}
          </label>
          <button
            class={`profiler-fn-profiling__toggle${enabled ? ' profiler-fn-profiling__toggle--active' : ''}`}
            onClick={onToggle}
            disabled={toggling}
          >
            {toggling ? '…' : enabled ? 'Enabled — click to disable' : 'Disabled — click to enable'}
          </button>
        </div>
      </div>

      {!enabled && (
        <p class="profiler-fn-profiling__hint">
          Enable function profiling to see where your app spends time.{' '}
          <strong>Lite</strong>: statistical sampling via stackprof — very low overhead (&lt;1%), enabled by default.{' '}
          <strong>Full</strong>: exhaustive TracePoint tracing with memory bytes — significant overhead.
        </p>
      )}

      {enabled && !hasData && (
        <p class="profiler-fn-profiling__hint">
          Function profiling is active. Data will appear on the next request.
        </p>
      )}

      {hasData && (
        <>
          {data!.frame_cap_reached && (
            <div class="profiler-fn-profiling__cap-warning">
              ⚠ Frame cap reached ({data!.max_frames} frames) — call tree is truncated. Increase "Max frames" to capture more.
            </div>
          )}

          <div class="profiler-flamegraph__stats" style={{ marginTop: '0.75rem' }}>
            <div class="stat-item">
              <span class="stat-label">Functions</span>
              <span class="stat-value">{data!.functions!.length}</span>
            </div>
            <div class="stat-item">
              <span class="stat-label">{isSampling ? 'Total Samples' : 'Total Calls'}</span>
              <span class="stat-value">{data!.total_calls}</span>
            </div>
            {!isObjectClock && (
              <div class="stat-item">
                <span class="stat-label">Wall</span>
                <span class="stat-value">{(data!.elapsed_wall_ms ?? data!.total_duration ?? 0).toFixed(2)} <small>ms</small></span>
              </div>
            )}
            {isSampling && !isObjectClock && data!.elapsed_cpu_ms != null && (
              <div class="stat-item">
                <span
                  class="stat-label"
                  title="CPU time excludes I/O waits (DB, network, sleep). Low CPU% = I/O-bound."
                >CPU</span>
                <span class="stat-value">
                  {data!.elapsed_cpu_ms.toFixed(2)} <small>ms</small>
                  {data!.elapsed_wall_ms != null && data!.elapsed_wall_ms > 0 && (
                    <small class="profiler-fn-profiling__cpu-pct">
                      {' '}({Math.round(data!.elapsed_cpu_ms / data!.elapsed_wall_ms * 100)}%)
                    </small>
                  )}
                </span>
              </div>
            )}
            {isObjectClock && (
              <div class="stat-item">
                <span class="stat-label">Allocations</span>
                <span class="stat-value">{data!.total_duration?.toLocaleString()} <small>obj</small></span>
              </div>
            )}
            {isSampling && (data!.gc_overhead_pct ?? 0) > 0 && (
              <div class="stat-item">
                <span class="stat-label" title={`${data!.gc_samples} samples during GC`}>GC</span>
                <span class={`stat-value${(data!.gc_overhead_pct ?? 0) >= 20 ? ' profiler-fn-profiling__gc--high' : (data!.gc_overhead_pct ?? 0) >= 5 ? ' profiler-fn-profiling__gc--medium' : ''}`}>
                  {data!.gc_overhead_pct}%
                </span>
              </div>
            )}
            {showAllocated && (
              <div class="stat-item">
                <span class="stat-label">Allocated</span>
                <span class="stat-value">{data!.total_allocated_objects?.toLocaleString()} <small>obj</small></span>
              </div>
            )}
            {showMemory && (
              <div class="stat-item">
                <span class="stat-label">Memory</span>
                <span class="stat-value">{formatBytes(data!.total_memory_bytes ?? 0)}</span>
              </div>
            )}
          </div>

          {rootCalls.length > 0 && (
            <FunctionFlameGraph
              rootCalls={rootCalls}
              onFrameSelect={handleFrameSelect}
              rendererRef={fnRendererRef}
              onHoverName={(name) => setHoveredFnName(name)}
            />
          )}

          {filterNames && (
            <div class="profiler-fn-profiling__filter-active">
              <span>Showing <strong>{filterLabel}</strong> + {filterNames.size - 1} child function{filterNames.size !== 2 ? 's' : ''}</span>
              <button class="profiler-fn-profiling__filter-clear" onClick={() => { setFilterNames(null); setFilterLabel(null) }}>✕ Clear</button>
            </div>
          )}

          <table class="profiler-table profiler-fn-profiling__table">
            <thead>
              <tr>
                <th>Function</th>
                <th>File</th>
                <th class={`profiler-text--right sortable${effectiveSortKey === 'calls' ? ' sortable--active' : ''}`} onClick={() => handleColClick('calls')}>{isSampling ? 'Samples' : 'Calls'} {sortIcon('calls')}</th>
                <th class={`profiler-text--right sortable${effectiveSortKey === 'total_duration' ? ' sortable--active' : ''}`} onClick={() => handleColClick('total_duration')}>{isObjectClock ? 'Total Alloc' : 'Total Time'} {sortIcon('total_duration')}</th>
                <th class={`profiler-text--right sortable${effectiveSortKey === 'self_duration' ? ' sortable--active' : ''}`} onClick={() => handleColClick('self_duration')}>{isObjectClock ? 'Self Alloc' : 'Self Time'} {sortIcon('self_duration')}</th>
                {showAllocated && <th class={`profiler-text--right sortable${effectiveSortKey === 'allocated_objects' ? ' sortable--active' : ''}`} onClick={() => handleColClick('allocated_objects')}>Objects {sortIcon('allocated_objects')}</th>}
                {showMemory && <th class={`profiler-text--right sortable${effectiveSortKey === 'memory_bytes' ? ' sortable--active' : ''}`} onClick={() => handleColClick('memory_bytes')}>Memory {sortIcon('memory_bytes')}</th>}
              </tr>
            </thead>
            <tbody>
              {displayedFunctions.map((fn, i) => (
                <tr
                  key={i}
                  class={hoveredFnName === fn.name ? 'profiler-fn-profiling__row--highlighted' : ''}
                  style={{ cursor: rootCalls.length > 0 ? 'pointer' : 'default' }}
                  onMouseEnter={() => {
                    setHoveredFnName(fn.name)
                    fnRendererRef.current?.setHighlightName(fn.name)
                  }}
                  onMouseLeave={() => {
                    setHoveredFnName(null)
                    fnRendererRef.current?.setHighlightName('')
                  }}
                  onClick={() => {
                    const node = findFirstNodeByName(rootCalls, fn.name)
                    if (node) {
                      fnRendererRef.current?.zoomTo(node)
                      handleFrameSelect(node)
                    }
                  }}
                >
                  <td class="profiler-fn-profiling__name">
                    {fn.recursive_calls > 0 && (
                      <span class="profiler-fn-profiling__recursive" title={`${fn.recursive_calls} recursive call(s)`}>↺</span>
                    )}
                    {fn.name}
                  </td>
                  <td class="profiler-text--muted profiler-text--xs" style={{ fontFamily: 'var(--profiler-font-mono)' }}>{fn.file}:{fn.line}</td>
                  <td class="profiler-text--right">{fn.calls}</td>
                  <td class="profiler-text--right">
                    {isObjectClock
                      ? <span class="profiler-text--muted">{fn.total_duration.toLocaleString()} <small>obj</small></span>
                      : <span class={fn.total_duration >= 100 ? 'badge-error' : fn.total_duration >= 10 ? 'badge-warning' : 'badge-success'}>{fn.total_duration.toFixed(2)} ms</span>
                    }
                  </td>
                  <td class="profiler-text--right">
                    {isObjectClock
                      ? <span class="profiler-text--muted">{fn.self_duration.toLocaleString()} <small>obj</small></span>
                      : <span class={fn.self_duration >= 50 ? 'badge-error' : fn.self_duration >= 5 ? 'badge-warning' : 'badge-success'}>{fn.self_duration.toFixed(2)} ms</span>
                    }
                  </td>
                  {showAllocated && <td class="profiler-text--right profiler-text--muted">{fn.allocated_objects.toLocaleString()} <small>obj</small></td>}
                  {showMemory && <td class="profiler-text--right profiler-text--muted">{formatBytes(fn.memory_bytes)}</td>}
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </div>
  )
}

function FunctionFlameGraph({ rootCalls, onFrameSelect, rendererRef: externalRendererRef, onHoverName }: {
  rootCalls: FlameGraphNode[]
  onFrameSelect?: (node: FlameGraphNode | null) => void
  rendererRef?: { current: FlameGraphRenderer | null }
  onHoverName?: (name: string | null) => void
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const containerRef = useRef<HTMLDivElement>(null)
  const rendererRef = useRef<FlameGraphRenderer | null>(null)
  const onFrameSelectRef = useRef(onFrameSelect)
  const onHoverNameRef = useRef(onHoverName)
  const [isZoomed, setIsZoomed] = useState(false)

  useEffect(() => { onFrameSelectRef.current = onFrameSelect }, [onFrameSelect])
  useEffect(() => { onHoverNameRef.current = onHoverName }, [onHoverName])

  const totalDuration = rootCalls.reduce((sum, n) => sum + n.duration, 0)

  useEffect(() => {
    if (!rootCalls.length || !canvasRef.current || !containerRef.current) return

    const container = containerRef.current
    const canvas = canvasRef.current

    const tooltip = new FlameGraphTooltip(container, totalDuration)
    const breadcrumbs = new FlameGraphBreadcrumbs(container, (node: FlameGraphNode | null) => {
      if (node) {
        rendererRef.current?.zoomTo(node)
        onFrameSelectRef.current?.(node)
      } else {
        rendererRef.current?.resetZoom()
        onFrameSelectRef.current?.(null)
      }
    })
    container.insertBefore(breadcrumbs['el'], canvas)

    const renderer = new FlameGraphRenderer(canvas, rootCalls, {
      onHover: (frame: FlatFrame | null, x: number, y: number) => {
        if (frame) {
          tooltip.show(frame, x, y)
          onHoverNameRef.current?.(frame.node.name)
        } else {
          tooltip.hide()
          onHoverNameRef.current?.(null)
        }
      },
      onClick: (frame: FlatFrame) => {
        setIsZoomed(true)
        onFrameSelectRef.current?.(frame.node)
        renderer.zoomTo(frame.node)
      },
      onZoomChange: (ancestors: FlameGraphNode[]) => {
        breadcrumbs.update(ancestors)
        setIsZoomed(ancestors.length > 0)
        if (ancestors.length === 0) onFrameSelectRef.current?.(null)
      },
    })
    rendererRef.current = renderer
    if (externalRendererRef) externalRendererRef.current = renderer

    const handleResize = () => renderer.resizeCanvas()
    window.addEventListener('resize', handleResize)
    const handleTheme = () => renderer.render()
    document.addEventListener('profiler:theme-change', handleTheme)

    return () => {
      renderer.destroy()
      tooltip.destroy()
      breadcrumbs.destroy()
      window.removeEventListener('resize', handleResize)
      document.removeEventListener('profiler:theme-change', handleTheme)
      rendererRef.current = null
      if (externalRendererRef) externalRendererRef.current = null
    }
  }, [rootCalls])

  const handleReset = () => {
    rendererRef.current?.resetZoom()
    setIsZoomed(false)
    onFrameSelectRef.current?.(null)
  }



  return (
    <div class="profiler-fn-profiling__flamegraph">
      <div class="profiler-flamegraph__controls">
        {isZoomed && (
          <button class="profiler-flamegraph__reset" onClick={handleReset}>Reset Zoom</button>
        )}
        <span class="profiler-flamegraph__hint">Click to zoom & filter table · scroll to zoom in/out · drag to pan</span>
      </div>
      <div class="profiler-flamegraph__canvas-container" ref={containerRef}>
        <canvas ref={canvasRef} class="profiler-flamegraph__canvas" style={{ width: '100%' }} />
      </div>
    </div>
  )
}
