import { useRef, useEffect, useState } from 'preact/hooks'
import type { FlameGraphData, FlameGraphNode, FlameGraphCategory, PerformanceData } from '../../../dashboard/types'
import { FlameGraphRenderer, FlatFrame } from '../../../flamegraph/FlameGraphRenderer'
import { FlameGraphTooltip } from '../../../flamegraph/FlameGraphTooltip'
import { FlameGraphBreadcrumbs } from '../../../flamegraph/FlameGraphBreadcrumbs'

const CATEGORY_COLORS: Record<FlameGraphCategory, string> = {
  controller: '#60a5fa',
  view: '#34d399',
  partial: '#f59e0b',
  sql: '#fb923c',
  cache: '#a78bfa',
  http: '#f87171'
}

const CATEGORY_LABELS: Record<FlameGraphCategory, string> = {
  controller: 'Controller',
  view: 'View',
  partial: 'Partial',
  sql: 'SQL',
  cache: 'Cache',
  http: 'HTTP'
}

interface Props {
  flamegraphData: FlameGraphData | undefined
  perfData: PerformanceData | undefined
}

export function FlameGraphTab({ flamegraphData, perfData }: Props) {
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
        <div class="profiler-empty">
          <p class="profiler-empty__description">No performance events recorded</p>
        </div>
      )
    }

    return (
      <>
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
      </>
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
    </div>
  )
}
