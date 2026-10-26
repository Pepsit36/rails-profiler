import { describe, it, expect, beforeEach, vi } from 'vitest'
import { FlameGraphRenderer, type FlameGraphCallbacks } from '../../app/assets/typescript/profiler/flamegraph/FlameGraphRenderer'
import type { FlameGraphNode } from '../../app/assets/typescript/profiler/dashboard/types'

// Mock Canvas context
const mockContext = {
  clearRect: vi.fn(),
  fillRect: vi.fn(),
  fillText: vi.fn(),
  measureText: vi.fn(() => ({ width: 50 })),
  setTransform: vi.fn(),
  beginPath: vi.fn(),
  moveTo: vi.fn(),
  lineTo: vi.fn(),
  quadraticCurveTo: vi.fn(),
  closePath: vi.fn(),
  fill: vi.fn(),
  stroke: vi.fn(),
  strokeStyle: '',
  fillStyle: '',
  globalAlpha: 1,
  font: '',
  textBaseline: ''
}

describe('FlameGraphRenderer - large frame counts', () => {
  let canvas: HTMLCanvasElement
  let callbacks: FlameGraphCallbacks

  beforeEach(() => {
    canvas = document.createElement('canvas')
    canvas.width = 800
    canvas.height = 600
    vi.spyOn(canvas, 'getContext').mockReturnValue(mockContext as any)

    callbacks = {
      onHover: vi.fn(),
      onClick: vi.fn(),
      onZoomChange: vi.fn()
    }
  })

  it('should handle more than 150000 frames without stack overflow', () => {
    const manyFrames: FlameGraphNode[] = []
    for (let i = 0; i < 150100; i++) {
      manyFrames.push({
        name: `frame_${i}`,
        category: 'method' as const,
        duration: 1,
        started_at: i,
        finished_at: i + 1,
        children: []
      })
    }

    expect(() => {
      const renderer = new FlameGraphRenderer(canvas, manyFrames, callbacks)
      renderer.destroy()
    }).not.toThrow()
  })

  it('should compute global bounds with many frames', () => {
    const frames: FlameGraphNode[] = []
    for (let i = 0; i < 1000; i++) {
      frames.push({
        name: `frame_${i}`,
        category: 'method' as const,
        duration: 10,
        started_at: i * 10,
        finished_at: i * 10 + 10,
        children: []
      })
    }

    expect(() => {
      const renderer = new FlameGraphRenderer(canvas, frames, callbacks)
      renderer.destroy()
    }).not.toThrow()
  })
})
