import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

let host: HTMLElement
beforeEach(() => {
  host = document.createElement('div')
  document.body.appendChild(host)
})
afterEach(() => {
  render(null, host)
  host.remove()
  sessionStorage.clear()
  vi.resetModules()
  vi.unstubAllGlobals()
})

async function mountSelector(response: () => Promise<Response>) {
  vi.resetModules()
  const fetchMock = vi.fn(response)
  vi.stubGlobal('fetch', fetchMock)
  const { ProfilerSelector } = await import('../../app/assets/typescript/profiler/components/ProfilerSelector')
  const client = new QueryClient({ defaultOptions: { queries: { staleTime: 30_000, retry: 1 } } })
  await act(() => render(<QueryClientProvider client={client}><ProfilerSelector /></QueryClientProvider>, host))
  return fetchMock
}

const slaves = { slaves: [
  { name: 'web-2', url: 'http://web-2', status: 'online', registered_at: '2026-01-01T00:00:00Z', last_heartbeat_at: '2026-01-01T00:00:00Z' },
  { name: 'web-3', url: 'http://web-3', status: 'offline', registered_at: '2026-01-01T00:00:00Z', last_heartbeat_at: '2026-01-01T00:00:00Z' },
] }

describe('ProfilerSelector', () => {
  it('lists the slaves from the cluster endpoint of the master', async () => {
    const fetchMock = await mountSelector(() => Promise.resolve(new Response(JSON.stringify(slaves), { status: 200 })))
    await vi.waitFor(() => expect(host.querySelector('select')).not.toBeNull())

    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0][0]).toBe('/_profiler/api/cluster/slaves')
    expect([...host.querySelectorAll('option')].map(o => o.textContent?.trim())).toEqual(['Local (master)', 'web-2', 'web-3 (offline)'])
    expect((host.querySelectorAll('option')[2] as HTMLOptionElement).disabled).toBe(true)
  })

  it('still asks the master, not the proxy of the slave being viewed', async () => {
    sessionStorage.setItem('profiler-active-slave', 'web-2')
    const fetchMock = await mountSelector(() => Promise.resolve(new Response(JSON.stringify(slaves), { status: 200 })))
    await vi.waitFor(() => expect(host.querySelector('select')).not.toBeNull())

    expect(fetchMock.mock.calls[0][0]).toBe('/_profiler/api/cluster/slaves')
  })

  it('renders nothing, and asks once, when the request fails', async () => {
    const fetchMock = await mountSelector(() => Promise.resolve(new Response('{"error":"no"}', { status: 403 })))
    await new Promise(resolve => setTimeout(resolve, 50))

    expect(host.innerHTML).toBe('')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })
})
