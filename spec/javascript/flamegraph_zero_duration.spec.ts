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

describe('FlameGraphRenderer - zero-duration and tiny frames', () => {
  let callbacks: FlameGraphCallbacks
  let drawn: number[]
  const make = (nodes: FlameGraphNode[]) => {
    const renderer = new FlameGraphRenderer(makeCanvas(), nodes, callbacks)
    drawn = []
    ;(renderer as any).roundRect = (_c: any, _x: number, _y: number, w: number) => { drawn.push(w) }
    return renderer
  }

  beforeEach(() => {
    callbacks = { onHover: vi.fn(), onClick: vi.fn(), onZoomChange: vi.fn() }
  })

  it('draws a zero-duration frame with a width of at least 1px', () => {
    const renderer = make([node('parent', 0, 100, [node('zero', 50, 50)])])
    renderer.render()
    expect(drawn).toContain(1)
    renderer.destroy()
  })

  it('still culls tiny non-zero frames below half a pixel', () => {
    const renderer = make([node('parent', 0, 100, [node('tiny', 50, 50.001)])])
    renderer.render()
    expect(drawn).toEqual([800])
    renderer.destroy()
  })

  it('lets the user hover a zero-duration frame', () => {
    const renderer = make([node('parent', 0, 100, [node('zero', 50.1, 50.1)])])
    // x = 400.8: the frame spans 400.8..401.8, so 401 only hits it once widened
    const canvas = (renderer as any).canvas as HTMLCanvasElement
    canvas.dispatchEvent(mouse('mousemove', 401, 30))
    const frame = (callbacks.onHover as any).mock.calls.at(-1)[0]
    expect(frame?.node.name).toBe('zero')
    renderer.destroy()
  })
})
