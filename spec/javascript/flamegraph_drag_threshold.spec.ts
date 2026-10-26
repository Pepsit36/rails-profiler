import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { FlameGraphRenderer, type FlameGraphCallbacks } from '../../app/assets/typescript/profiler/flamegraph/FlameGraphRenderer'
import type { FlameGraphNode } from '../../app/assets/typescript/profiler/dashboard/types'

const mockContext = {
  clearRect: vi.fn(), fillRect: vi.fn(), fillText: vi.fn(),
  measureText: vi.fn(() => ({ width: 50 })), setTransform: vi.fn(),
  beginPath: vi.fn(), moveTo: vi.fn(), lineTo: vi.fn(), quadraticCurveTo: vi.fn(),
  closePath: vi.fn(), fill: vi.fn(), stroke: vi.fn(),
  strokeStyle: '', fillStyle: '', globalAlpha: 1, font: '', textBaseline: ''
}

function node(name: string, start: number, end: number, children: FlameGraphNode[] = []): FlameGraphNode {
  return { name, category: 'method', duration: end - start, started_at: start, finished_at: end, children } as FlameGraphNode
}

function makeCanvas(): HTMLCanvasElement {
  const canvas = document.createElement('canvas')
  vi.spyOn(canvas, 'getContext').mockReturnValue(mockContext as any)
  vi.spyOn(canvas, 'getBoundingClientRect').mockReturnValue(
    { left: 0, top: 0, right: 800, bottom: 600, width: 800, height: 600, x: 0, y: 0, toJSON: () => ({}) } as DOMRect
  )
  return canvas
}

function mouse(type: string, clientX: number, clientY = 10) {
  return new MouseEvent(type, { clientX, clientY, bubbles: true })
}

describe('FlameGraphRenderer - drag threshold', () => {
  let canvas: HTMLCanvasElement
  let callbacks: FlameGraphCallbacks
  let renderer: FlameGraphRenderer

  beforeEach(() => {
    canvas = makeCanvas()
    callbacks = { onHover: vi.fn(), onClick: vi.fn(), onZoomChange: vi.fn() }
    renderer = new FlameGraphRenderer(canvas, [node('root', 0, 100)], callbacks)
  })
  afterEach(() => renderer.destroy())

  function gesture(moves: number[]) {
    canvas.dispatchEvent(mouse('mousedown', 400))
    for (const x of moves) window.dispatchEvent(mouse('mousemove', x))
    window.dispatchEvent(mouse('mouseup', moves[moves.length - 1]))
    canvas.dispatchEvent(mouse('click', moves[moves.length - 1]))
  }

  it('does not click-zoom after a drag of more than 3px', () => {
    gesture([410])
    expect(callbacks.onClick).not.toHaveBeenCalled()
  })

  it('still clicks after a movement of 2px', () => {
    gesture([402])
    expect(callbacks.onClick).toHaveBeenCalledTimes(1)
  })

  it('does not click when the drag returns close to its start', () => {
    gesture([500, 401])
    expect(callbacks.onClick).not.toHaveBeenCalled()
  })

  it('resets the drag distance on the next mousedown', () => {
    gesture([450])
    canvas.dispatchEvent(mouse('mousedown', 400))
    window.dispatchEvent(mouse('mouseup', 400))
    canvas.dispatchEvent(mouse('click', 400))
    expect(callbacks.onClick).toHaveBeenCalledTimes(1)
  })
})
