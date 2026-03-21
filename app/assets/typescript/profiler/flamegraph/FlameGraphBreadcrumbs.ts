import type { FlameGraphNode } from '../dashboard/types'

export class FlameGraphBreadcrumbs {
  private el: HTMLDivElement
  private onNavigate: (node: FlameGraphNode | null) => void

  constructor(container: HTMLElement, onNavigate: (node: FlameGraphNode | null) => void) {
    this.onNavigate = onNavigate
    this.el = document.createElement('div')
    this.el.className = 'profiler-flamegraph__breadcrumbs'
    container.appendChild(this.el)
  }

  update(ancestors: FlameGraphNode[]) {
    this.el.textContent = ''

    if (ancestors.length === 0) {
      this.el.style.display = 'none'
      return
    }

    this.el.style.display = 'flex'

    // Root link
    const rootLink = document.createElement('button')
    rootLink.className = 'breadcrumb-item'
    rootLink.textContent = 'Root'
    rootLink.addEventListener('click', () => this.onNavigate(null))
    this.el.appendChild(rootLink)

    for (const node of ancestors) {
      const sep = document.createElement('span')
      sep.className = 'breadcrumb-separator'
      sep.textContent = '\u203A'
      this.el.appendChild(sep)

      const link = document.createElement('button')
      link.className = 'breadcrumb-item'
      const name = node.name.length > 30 ? node.name.slice(0, 30) + '...' : node.name
      link.textContent = name
      link.addEventListener('click', () => this.onNavigate(node))
      this.el.appendChild(link)
    }
  }

  destroy() {
    this.el.remove()
  }
}
