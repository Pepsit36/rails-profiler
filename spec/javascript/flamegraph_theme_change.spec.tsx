import { describe, it, expect, vi, afterEach } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { FlameGraphTab } from '../../app/assets/typescript/profiler/components/dashboard/tabs/FlameGraphTab'
import { FlameGraphRenderer } from '../../app/assets/typescript/profiler/flamegraph/FlameGraphRenderer'

vi.mock('../../app/assets/typescript/profiler/generated/api', () => ({
  useUpdateFunctionProfiling: () => ({ mutateAsync: vi.fn() })
}))

const flamegraphData: any = {
  total_duration: 100,
  root_events: [{ name: 'root', category: 'controller', duration: 100, started_at: 0, finished_at: 100, children: [] }]
}

let host: HTMLElement
afterEach(() => {
  render(null, host)
  host.remove()
  vi.restoreAllMocks()
})

async function mount() {
  host = document.createElement('div')
  document.body.appendChild(host)
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(new Proxy({}, {
    get: (_t, p) => (p === 'measureText' ? () => ({ width: 10 }) : () => {}),
    set: () => true
  }) as any)
  await act(() => render(<FlameGraphTab flamegraphData={flamegraphData} perfData={undefined} functionProfileData={undefined} />, host))
}

describe('FlameGraphTab - theme change', () => {
  it('re-renders the flamegraph when profiler:theme-change is dispatched on window', async () => {
    await mount()
    const spy = vi.spyOn(FlameGraphRenderer.prototype, 'render')
    window.dispatchEvent(new CustomEvent('profiler:theme-change'))
    expect(spy).toHaveBeenCalledTimes(1)
  })

  it('stops re-rendering once the tab is unmounted', async () => {
    await mount()
    const spy = vi.spyOn(FlameGraphRenderer.prototype, 'render')
    await act(() => render(null, host))
    window.dispatchEvent(new CustomEvent('profiler:theme-change'))
    expect(spy).not.toHaveBeenCalled()
  })
})
