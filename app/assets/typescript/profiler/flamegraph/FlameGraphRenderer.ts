import type { FlameGraphNode, FlameGraphCategory } from '../dashboard/types'

const CATEGORY_COLORS: Record<FlameGraphCategory, string> = {
  controller: '#60a5fa',
  view: '#34d399',
  partial: '#f59e0b',
  sql: '#fb923c',
  cache: '#a78bfa',
  http: '#f87171',
  custom: '#e879f9'
}

const FRAME_HEIGHT = 24
const FRAME_GAP = 1
const ROW_HEIGHT = FRAME_HEIGHT + FRAME_GAP
const MIN_TEXT_WIDTH = 60
const ZOOM_ANIM_MS = 300

export interface FlatFrame {
  node: FlameGraphNode
  depth: number
  absStart: number
  absEnd: number
}

export interface Viewport {
  start: number
  end: number
}

export interface FlameGraphCallbacks {
  onHover: (frame: FlatFrame | null, x: number, y: number) => void
  onClick: (frame: FlatFrame) => void
  onZoomChange: (ancestors: FlameGraphNode[]) => void
  onSearchResults?: (matchCount: number, totalCount: number) => void
}

export class FlameGraphRenderer {
  private canvas: HTMLCanvasElement
  private ctx: CanvasRenderingContext2D
  private frames: FlatFrame[] = []
  private maxDepth = 0
  private globalStart = 0
  private globalEnd = 0
  private viewport: Viewport = { start: 0, end: 0 }
  private targetViewport: Viewport = { start: 0, end: 0 }
  private animating = false
  private animStart = 0
  private prevViewport: Viewport = { start: 0, end: 0 }
  private callbacks: FlameGraphCallbacks
  private dpr = 1
  private hoveredFrame: FlatFrame | null = null
  private zoomStack: FlameGraphNode[] = []
  private searchQuery = ''
  private isPanning = false
  private panStartX = 0
  private panStartViewport: Viewport = { start: 0, end: 0 }
  private boundHandlers: Record<string, any> = {}

  constructor(canvas: HTMLCanvasElement, rootEvents: FlameGraphNode[], callbacks: FlameGraphCallbacks) {
    this.canvas = canvas
    this.ctx = canvas.getContext('2d')!
    this.callbacks = callbacks

    this.flatten(rootEvents)
    this.computeGlobalBounds()
    this.viewport = { start: this.globalStart, end: this.globalEnd }
    this.targetViewport = { ...this.viewport }

    this.setupCanvas()
    this.bindEvents()
    this.render()
  }

  private flatten(rootEvents: FlameGraphNode[]) {
    this.frames = []
    this.maxDepth = 0

    const walk = (nodes: FlameGraphNode[], depth: number) => {
      for (const node of nodes) {
        this.frames.push({
          node,
          depth,
          absStart: node.started_at,
          absEnd: node.finished_at
        })
        if (depth > this.maxDepth) this.maxDepth = depth
        if (node.children?.length) walk(node.children, depth + 1)
      }
    }

    walk(rootEvents, 0)
  }

  private computeGlobalBounds() {
    if (this.frames.length === 0) {
      this.globalStart = 0
      this.globalEnd = 1
      return
    }
    this.globalStart = Math.min(...this.frames.map(f => f.absStart))
    this.globalEnd = Math.max(...this.frames.map(f => f.absEnd))
    if (this.globalEnd <= this.globalStart) this.globalEnd = this.globalStart + 1
  }

  private setupCanvas() {
    this.dpr = window.devicePixelRatio || 1
    this.resizeCanvas()
  }

  resizeCanvas() {
    const rect = this.canvas.getBoundingClientRect()
    const w = rect.width
    const h = (this.maxDepth + 1) * ROW_HEIGHT + 8
    this.canvas.width = w * this.dpr
    this.canvas.height = h * this.dpr
    this.canvas.style.height = `${h}px`
    this.ctx.setTransform(this.dpr, 0, 0, this.dpr, 0, 0)
    this.render()
  }

  private bindEvents() {
    this.boundHandlers.mousemove = (e: MouseEvent) => this.onMouseMove(e)
    this.boundHandlers.mouseleave = () => this.onMouseLeave()
    this.boundHandlers.click = (e: MouseEvent) => this.onClickEvent(e)
    this.boundHandlers.wheel = (e: WheelEvent) => this.onWheel(e)
    this.boundHandlers.mousedown = (e: MouseEvent) => this.onMouseDown(e)
    this.boundHandlers.mouseupmove = (e: MouseEvent) => this.onMouseUpOrMove(e)
    this.boundHandlers.mouseup = () => this.onMouseUp()

    this.canvas.addEventListener('mousemove', this.boundHandlers.mousemove)
    this.canvas.addEventListener('mouseleave', this.boundHandlers.mouseleave)
    this.canvas.addEventListener('click', this.boundHandlers.click)
    this.canvas.addEventListener('wheel', this.boundHandlers.wheel, { passive: false })
    this.canvas.addEventListener('mousedown', this.boundHandlers.mousedown)
    window.addEventListener('mousemove', this.boundHandlers.mouseupmove)
    window.addEventListener('mouseup', this.boundHandlers.mouseup)
  }

  private hitTest(clientX: number, clientY: number): FlatFrame | null {
    const rect = this.canvas.getBoundingClientRect()
    const mx = clientX - rect.left
    const my = clientY - rect.top
    const w = rect.width
    const vpRange = this.viewport.end - this.viewport.start

    for (let i = this.frames.length - 1; i >= 0; i--) {
      const f = this.frames[i]
      const x = ((f.absStart - this.viewport.start) / vpRange) * w
      const fw = ((f.absEnd - f.absStart) / vpRange) * w
      const y = f.depth * ROW_HEIGHT

      if (mx >= x && mx <= x + fw && my >= y && my <= y + FRAME_HEIGHT) {
        return f
      }
    }
    return null
  }

  private onMouseMove(e: MouseEvent) {
    if (this.isPanning) return
    const frame = this.hitTest(e.clientX, e.clientY)
    this.hoveredFrame = frame
    this.canvas.style.cursor = frame ? 'pointer' : 'default'
    this.callbacks.onHover(frame, e.clientX, e.clientY)
    this.render()
  }

  private onMouseLeave() {
    this.hoveredFrame = null
    this.canvas.style.cursor = 'default'
    this.callbacks.onHover(null, 0, 0)
    this.render()
  }

  private onClickEvent(e: MouseEvent) {
    if (this.isPanning) return
    const frame = this.hitTest(e.clientX, e.clientY)
    if (frame) {
      this.callbacks.onClick(frame)
      this.zoomTo(frame.node)
    }
  }

  private onWheel(e: WheelEvent) {
    e.preventDefault()
    const rect = this.canvas.getBoundingClientRect()
    const mx = e.clientX - rect.left
    const ratio = mx / rect.width
    const vpRange = this.viewport.end - this.viewport.start

    const zoomFactor = e.deltaY > 0 ? 1.3 : 0.7
    const newRange = Math.min(this.globalEnd - this.globalStart, vpRange * zoomFactor)

    const center = this.viewport.start + ratio * vpRange
    let newStart = center - ratio * newRange
    let newEnd = center + (1 - ratio) * newRange

    // Clamp to global bounds
    if (newStart < this.globalStart) {
      newStart = this.globalStart
      newEnd = newStart + newRange
    }
    if (newEnd > this.globalEnd) {
      newEnd = this.globalEnd
      newStart = newEnd - newRange
    }

    this.animateViewport({ start: newStart, end: newEnd })
    this.updateZoomStack(newStart, newEnd)
  }

  private onMouseDown(e: MouseEvent) {
    if (e.button !== 0) return
    this.isPanning = true
    this.panStartX = e.clientX
    this.panStartViewport = { ...this.viewport }
    this.canvas.style.cursor = 'grabbing'
  }

  private onMouseUpOrMove(e: MouseEvent) {
    if (!this.isPanning) return
    const dx = e.clientX - this.panStartX
    const rect = this.canvas.getBoundingClientRect()
    const vpRange = this.panStartViewport.end - this.panStartViewport.start
    const shift = -(dx / rect.width) * vpRange

    let newStart = this.panStartViewport.start + shift
    let newEnd = this.panStartViewport.end + shift

    // Clamp
    if (newStart < this.globalStart) {
      newEnd += this.globalStart - newStart
      newStart = this.globalStart
    }
    if (newEnd > this.globalEnd) {
      newStart -= newEnd - this.globalEnd
      newEnd = this.globalEnd
    }

    this.viewport = { start: newStart, end: newEnd }
    this.targetViewport = { ...this.viewport }
    this.render()
  }

  private onMouseUp() {
    if (this.isPanning) {
      this.isPanning = false
      this.canvas.style.cursor = 'default'
    }
  }

  zoomTo(node: FlameGraphNode) {
    // Build ancestor path
    const ancestors: FlameGraphNode[] = []
    const findPath = (nodes: FlameGraphNode[], target: FlameGraphNode, path: FlameGraphNode[]): boolean => {
      for (const n of nodes) {
        if (n === target) {
          ancestors.push(...path, n)
          return true
        }
        if (n.children?.length && findPath(n.children, target, [...path, n])) return true
      }
      return false
    }
    // We need rootEvents for this - search through frames for depth 0
    const rootNodes = this.frames.filter(f => f.depth === 0).map(f => f.node)
    findPath(rootNodes, node, [])

    this.zoomStack = ancestors
    this.animateViewport({ start: node.started_at, end: node.finished_at })
    this.callbacks.onZoomChange(ancestors)
  }

  resetZoom() {
    this.zoomStack = []
    this.animateViewport({ start: this.globalStart, end: this.globalEnd })
    this.callbacks.onZoomChange([])
  }

  private updateZoomStack(start: number, end: number) {
    // If we've zoomed all the way out, clear the stack
    const fullRange = this.globalEnd - this.globalStart
    const newRange = end - start
    if (newRange >= fullRange * 0.99) {
      this.zoomStack = []
      this.callbacks.onZoomChange([])
    }
  }

  private animateViewport(target: Viewport) {
    this.prevViewport = { ...this.viewport }
    this.targetViewport = target
    this.animStart = performance.now()

    if (!this.animating) {
      this.animating = true
      this.animLoop()
    }
  }

  private animLoop() {
    const t = Math.min(1, (performance.now() - this.animStart) / ZOOM_ANIM_MS)
    const ease = t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2

    this.viewport = {
      start: this.prevViewport.start + (this.targetViewport.start - this.prevViewport.start) * ease,
      end: this.prevViewport.end + (this.targetViewport.end - this.prevViewport.end) * ease
    }

    this.render()

    if (t < 1) {
      requestAnimationFrame(() => this.animLoop())
    } else {
      this.animating = false
      this.viewport = { ...this.targetViewport }
      this.render()
    }
  }

  setSearchQuery(query: string) {
    this.searchQuery = query
    this.render()
  }

  render() {
    const ctx = this.ctx
    const w = this.canvas.width / this.dpr
    const h = this.canvas.height / this.dpr
    const vpRange = this.viewport.end - this.viewport.start

    ctx.clearRect(0, 0, w, h)

    // Read theme colors from CSS
    const style = getComputedStyle(this.canvas)
    const textColor = style.getPropertyValue('--profiler-text').trim() || '#eef2f7'
    const textMuted = style.getPropertyValue('--profiler-text-muted').trim() || '#5e7080'

    const searchLower = this.searchQuery.toLowerCase()
    const hasSearch = searchLower.length > 0

    // Compute search match counts before rendering
    if (hasSearch && this.callbacks.onSearchResults) {
      let matchCount = 0
      for (const f of this.frames) {
        if (f.node.name.toLowerCase().includes(searchLower)) matchCount++
      }
      this.callbacks.onSearchResults(matchCount, this.frames.length)
    }

    for (const frame of this.frames) {
      const x = ((frame.absStart - this.viewport.start) / vpRange) * w
      const fw = ((frame.absEnd - frame.absStart) / vpRange) * w
      const y = frame.depth * ROW_HEIGHT

      // Skip invisible frames
      if (x + fw < 0 || x > w || fw < 0.5) continue

      const color = CATEGORY_COLORS[frame.node.category as FlameGraphCategory] || '#a78bfa'
      const isHovered = frame === this.hoveredFrame
      const isMatch = !hasSearch || frame.node.name.toLowerCase().includes(searchLower)

      // Draw frame rect
      ctx.fillStyle = isHovered ? this.lightenColor(color, 0.2) : color
      ctx.globalAlpha = hasSearch && !isMatch ? 0.2 : (isHovered ? 1 : 0.85)
      this.roundRect(ctx, x, y, fw, FRAME_HEIGHT, 3)
      ctx.fill()
      ctx.globalAlpha = 1

      // Draw border
      if (isHovered) {
        ctx.strokeStyle = '#ffffff'
        ctx.lineWidth = 1.5
        this.roundRect(ctx, x, y, fw, FRAME_HEIGHT, 3)
        ctx.stroke()
      } else if (hasSearch && isMatch) {
        ctx.strokeStyle = '#ffffff'
        ctx.lineWidth = 1
        ctx.globalAlpha = 0.5
        this.roundRect(ctx, x, y, fw, FRAME_HEIGHT, 3)
        ctx.stroke()
        ctx.globalAlpha = 1
      }

      // Draw text if wide enough
      if (fw > MIN_TEXT_WIDTH && isMatch) {
        ctx.fillStyle = this.getTextColor(color)
        ctx.font = '11px "JetBrains Mono", monospace'
        ctx.textBaseline = 'middle'

        const label = frame.node.name
        const duration = `${frame.node.duration.toFixed(1)}ms`
        const maxTextWidth = fw - 8
        const durationWidth = ctx.measureText(duration).width

        if (maxTextWidth > durationWidth + 20) {
          // Render name + duration
          const nameMaxWidth = maxTextWidth - durationWidth - 8
          ctx.fillText(this.truncateText(ctx, label, nameMaxWidth), x + 4, y + FRAME_HEIGHT / 2)
          ctx.fillStyle = isHovered ? textColor : textMuted
          ctx.fillText(duration, x + fw - durationWidth - 4, y + FRAME_HEIGHT / 2)
        } else {
          ctx.fillText(this.truncateText(ctx, label, maxTextWidth), x + 4, y + FRAME_HEIGHT / 2)
        }
      }
    }
  }

  private roundRect(ctx: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
    ctx.beginPath()
    ctx.moveTo(x + r, y)
    ctx.lineTo(x + w - r, y)
    ctx.quadraticCurveTo(x + w, y, x + w, y + r)
    ctx.lineTo(x + w, y + h - r)
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h)
    ctx.lineTo(x + r, y + h)
    ctx.quadraticCurveTo(x, y + h, x, y + h - r)
    ctx.lineTo(x, y + r)
    ctx.quadraticCurveTo(x, y, x + r, y)
    ctx.closePath()
  }

  private truncateText(ctx: CanvasRenderingContext2D, text: string, maxWidth: number): string {
    if (ctx.measureText(text).width <= maxWidth) return text
    let truncated = text
    while (truncated.length > 0 && ctx.measureText(truncated + '...').width > maxWidth) {
      truncated = truncated.slice(0, -1)
    }
    return truncated.length > 0 ? truncated + '...' : ''
  }

  private lightenColor(hex: string, amount: number): string {
    const num = parseInt(hex.slice(1), 16)
    const r = Math.min(255, ((num >> 16) & 0xff) + Math.round(255 * amount))
    const g = Math.min(255, ((num >> 8) & 0xff) + Math.round(255 * amount))
    const b = Math.min(255, (num & 0xff) + Math.round(255 * amount))
    return `rgb(${r},${g},${b})`
  }

  private getTextColor(bgHex: string): string {
    const num = parseInt(bgHex.slice(1), 16)
    const r = (num >> 16) & 0xff
    const g = (num >> 8) & 0xff
    const b = num & 0xff
    const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255
    return luminance > 0.5 ? '#1a1a2e' : '#f0f0f0'
  }

  destroy() {
    this.canvas.removeEventListener('mousemove', this.boundHandlers.mousemove)
    this.canvas.removeEventListener('mouseleave', this.boundHandlers.mouseleave)
    this.canvas.removeEventListener('click', this.boundHandlers.click)
    this.canvas.removeEventListener('wheel', this.boundHandlers.wheel)
    this.canvas.removeEventListener('mousedown', this.boundHandlers.mousedown)
    window.removeEventListener('mousemove', this.boundHandlers.mouseupmove)
    window.removeEventListener('mouseup', this.boundHandlers.mouseup)
  }
}
