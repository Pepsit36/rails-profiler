import { describe, it, expect, vi, afterEach } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { FlameGraphTab } from '../../app/assets/typescript/profiler/components/dashboard/tabs/FlameGraphTab'

vi.mock('../../app/assets/typescript/profiler/generated/api', () => ({
  useUpdateFunctionProfiling: () => ({ mutateAsync: vi.fn() })
}))

let host: HTMLElement
afterEach(() => {
  render(null, host)
  host.remove()
  vi.restoreAllMocks()
})

async function mount(flamegraphData: any) {
  host = document.createElement('div')
  document.body.appendChild(host)
  vi.spyOn(HTMLCanvasElement.prototype, 'getContext').mockReturnValue(new Proxy({}, {
    get: (_t, p) => (p === 'measureText' ? () => ({ width: 10 }) : () => {}),
    set: () => true
  }) as any)
  await act(() => render(<FlameGraphTab flamegraphData={flamegraphData} perfData={undefined} functionProfileData={undefined} />, host))
}

const withEvents = {
  total_duration: 100,
  root_events: [{ name: 'root', category: 'controller', duration: 100, started_at: 0, finished_at: 100, children: [] }]
}

function pressCtrlF(key = 'f', init: KeyboardEventInit = { ctrlKey: true }) {
  const event = new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true, ...init })
  document.body.dispatchEvent(event)
  return event
}

describe('FlameGraphTab - Ctrl+F', () => {
  it('focuses the search input and prevents the browser find when the input exists', async () => {
    await mount(withEvents)
    const input = host.querySelector('.profiler-flamegraph__search-input') as HTMLInputElement
    expect(input).not.toBeNull()
    const event = pressCtrlF()
    expect(event.defaultPrevented).toBe(true)
    expect(document.activeElement).toBe(input)
  })

  it('supports Cmd+F', async () => {
    await mount(withEvents)
    expect(pressCtrlF('f', { metaKey: true }).defaultPrevented).toBe(true)
  })

  it('leaves the browser find alone when there is no search input', async () => {
    await mount({ total_duration: 0, root_events: [] })
    expect(host.querySelector('.profiler-flamegraph__search-input')).toBeNull()
    expect(pressCtrlF().defaultPrevented).toBe(false)
  })
})
