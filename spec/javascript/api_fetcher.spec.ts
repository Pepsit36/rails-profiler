import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

// cluster-context reads sessionStorage once, at import: seed it, then import afresh.
async function fetcherViewing(slave: string | null) {
  vi.resetModules()
  sessionStorage.clear()
  if (slave) sessionStorage.setItem('profiler-active-slave', slave)
  const fetchMock = vi.fn(async () => new Response('{}', { status: 200 }))
  vi.stubGlobal('fetch', fetchMock)
  const { apiFetch } = await import('../../app/assets/typescript/profiler/api-fetcher')
  return { apiFetch, fetchMock }
}

beforeEach(() => sessionStorage.clear())
afterEach(() => {
  sessionStorage.clear()
  vi.unstubAllGlobals()
})

describe('apiFetch slave prefix', () => {
  it('keeps the /slaves prefix on a route that is not a cluster route', async () => {
    const { apiFetch, fetchMock } = await fetcherViewing('web-2')
    await apiFetch({ url: '/_profiler/api/profiles', method: 'GET' })
    expect(fetchMock.mock.calls[0][0]).toBe('/_profiler/api/slaves/web-2/profiles')
  })

  it('never prefixes the cluster routes, which belong to the master', async () => {
    const { apiFetch, fetchMock } = await fetcherViewing('web-2')
    await apiFetch({ url: '/_profiler/api/cluster/slaves', method: 'GET' })
    expect(fetchMock.mock.calls[0][0]).toBe('/_profiler/api/cluster/slaves')
  })

  it('leaves every URL alone when no slave is being viewed', async () => {
    const { apiFetch, fetchMock } = await fetcherViewing(null)
    await apiFetch({ url: '/_profiler/api/profiles', method: 'GET' })
    expect(fetchMock.mock.calls[0][0]).toBe('/_profiler/api/profiles')
  })
})
