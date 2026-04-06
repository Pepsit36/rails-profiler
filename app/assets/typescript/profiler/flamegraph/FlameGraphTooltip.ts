import type { FlatFrame } from './FlameGraphRenderer'
import type { FlameGraphCategory } from '../dashboard/types'

const CATEGORY_LABELS: Record<FlameGraphCategory, string> = {
  controller: 'Controller',
  view: 'View',
  partial: 'Partial',
  sql: 'SQL',
  cache: 'Cache',
  http: 'HTTP',
  custom: 'Custom'
}

const CATEGORY_COLORS: Record<FlameGraphCategory, string> = {
  controller: '#60a5fa',
  view: '#34d399',
  partial: '#f59e0b',
  sql: '#fb923c',
  cache: '#a78bfa',
  http: '#f87171',
  custom: '#e879f9'
}

export class FlameGraphTooltip {
  private el: HTMLDivElement
  private totalDuration: number

  constructor(container: HTMLElement, totalDuration: number) {
    this.totalDuration = totalDuration
    this.el = document.createElement('div')
    this.el.className = 'profiler-flamegraph__tooltip'
    container.appendChild(this.el)
  }

  show(frame: FlatFrame, x: number, y: number) {
    const node = frame.node
    const category = node.category as FlameGraphCategory
    const color = CATEGORY_COLORS[category] || '#a78bfa'
    const label = CATEGORY_LABELS[category] || category
    const pctTotal = this.totalDuration > 0 ? ((node.duration / this.totalDuration) * 100).toFixed(1) : '0'

    // Build tooltip DOM safely (no innerHTML with user content)
    this.el.textContent = ''

    const header = document.createElement('div')
    header.className = 'tooltip-header'
    header.textContent = node.name
    this.el.appendChild(header)

    // Category row
    this.addRow('Category', () => {
      const badge = document.createElement('span')
      badge.className = 'tooltip-badge'
      badge.style.background = color
      badge.textContent = label
      return badge
    })

    // Duration row
    this.addRow('Duration', () => {
      const span = document.createElement('span')
      span.className = 'value'
      span.textContent = `${node.duration.toFixed(2)} ms`
      return span
    })

    // % of total row
    this.addRow('% of total', () => {
      const span = document.createElement('span')
      span.className = 'value'
      span.textContent = `${pctTotal}%`
      return span
    })

    // Payload details
    if (node.payload) {
      let payloadText: string | null = null
      if (category === 'sql' && node.payload.sql) {
        payloadText = node.payload.sql.length > 200 ? node.payload.sql.slice(0, 200) + '...' : node.payload.sql
      } else if (category === 'cache' && node.payload.key) {
        payloadText = `Key: ${node.payload.key}`
      } else if (category === 'http' && node.payload.url) {
        payloadText = node.payload.url
      } else if (category === 'custom' && Object.keys(node.payload).length > 0) {
        const entries = Object.entries(node.payload)
          .map(([k, v]) => `${k}: ${JSON.stringify(v)}`)
          .join('\n')
        payloadText = entries.length > 200 ? entries.slice(0, 200) + '...' : entries
      }
      if (payloadText) {
        const payloadDiv = document.createElement('div')
        payloadDiv.className = 'tooltip-payload'
        payloadDiv.textContent = payloadText
        this.el.appendChild(payloadDiv)
      }
    }

    // Position near cursor using viewport coordinates (fixed positioning)
    let left = x + 12
    let top = y - 8

    const tipRect = this.el.getBoundingClientRect()
    if (left + tipRect.width > window.innerWidth) left = x - tipRect.width - 12
    if (top + tipRect.height > window.innerHeight) top = y - tipRect.height - 8
    if (top < 0) top = 4

    this.el.style.left = `${left}px`
    this.el.style.top = `${top}px`
    this.el.classList.add('visible')
  }

  hide() {
    this.el.classList.remove('visible')
  }

  destroy() {
    this.el.remove()
  }

  private addRow(labelText: string, valueFactory: () => HTMLElement) {
    const row = document.createElement('div')
    row.className = 'tooltip-row'

    const labelEl = document.createElement('span')
    labelEl.className = 'label'
    labelEl.textContent = labelText
    row.appendChild(labelEl)

    row.appendChild(valueFactory())
    this.el.appendChild(row)
  }
}
