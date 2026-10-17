import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ToolbarErrorBoundary } from '../../app/assets/typescript/profiler/components/toolbar/ToolbarErrorBoundary'

let host: HTMLElement
beforeEach(() => {
  host = document.createElement('div')
  document.body.appendChild(host)
})
afterEach(() => {
  render(null, host)
  host.remove()
  vi.restoreAllMocks()
  vi.resetModules()
  vi.unstubAllGlobals()
})

describe('ToolbarErrorBoundary', () => {
  it('shows a message instead of an empty bar when a component throws, and lets the user retry', async () => {
    vi.spyOn(console, 'error').mockImplementation(() => {})
    let broken = true
    const Boom = () => {
      if (broken) throw new Error('boom')
      return <span>recovered</span>
    }
    await act(() => render(<ToolbarErrorBoundary><Boom /></ToolbarErrorBoundary>, host))
    expect(host.textContent).toContain('Profiler toolbar error')

    broken = false
    await act(() => { (host.querySelector('button') as HTMLButtonElement).click() })
    expect(host.textContent).toBe('recovered')
  })

  it('renders its children when nothing throws', async () => {
    await act(() => render(<ToolbarErrorBoundary><span>fine</span></ToolbarErrorBoundary>, host))
    expect(host.textContent).toBe('fine')
  })
})

describe('ToolbarMount', () => {
  async function mountWith(fetchImpl: () => Promise<unknown>) {
    vi.resetModules()
    vi.stubGlobal('fetch', vi.fn(fetchImpl))
    const { ToolbarMount } = await import('../../app/assets/typescript/profiler/components/toolbar/ToolbarMount')
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    await act(() => render(<QueryClientProvider client={client}><ToolbarMount token="abc" /></QueryClientProvider>, host))
    await vi.waitFor(() => expect(host.textContent).not.toBe(''))
    return client
  }

  it('shows an error state with a retry button when the toolbar API fails', async () => {
    await mountWith(() => Promise.resolve(new Response('{"error":"boom"}', { status: 500 })))
    expect(host.textContent).toContain('Profiler data could not be loaded')
    expect(host.querySelector('button')?.textContent).toBe('Retry')
  })

  it('retries when the button is pressed', async () => {
    await mountWith(() => Promise.resolve(new Response('{"error":"boom"}', { status: 500 })))
    const fetchMock = fetch as unknown as ReturnType<typeof vi.fn>
    const before = fetchMock.mock.calls.length
    await act(() => { (host.querySelector('button') as HTMLButtonElement).click() })
    await vi.waitFor(() => expect(fetchMock.mock.calls.length).toBeGreaterThan(before))
  })
})
