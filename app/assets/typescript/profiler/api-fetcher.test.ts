import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { apiFetch } from './api-fetcher'

const mockGetActiveSlavePrefix = vi.hoisted(() => vi.fn(() => ''))
vi.mock('./cluster-context', () => ({
  getActiveSlavePrefix: mockGetActiveSlavePrefix,
}))

describe('apiFetch slave prefix behavior', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    globalThis.fetch = vi.fn()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('does not apply slave prefix to /api/cluster/ URLs', async () => {
    mockGetActiveSlavePrefix.mockReturnValue('/slaves/node1')
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        status: 204,
        json: () => Promise.resolve({}),
      } as any),
    )

    await apiFetch({
      url: '/_profiler/api/cluster/list',
      method: 'GET',
    })

    const callUrl = (globalThis.fetch as any).mock.calls[0][0]
    expect(callUrl).toBe('/_profiler/api/cluster/list')
  })

  it('does not apply slave prefix to /api/toolbar/ URLs', async () => {
    mockGetActiveSlavePrefix.mockReturnValue('/slaves/node1')
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ profile: null }),
      } as any),
    )

    await apiFetch({
      url: '/_profiler/api/toolbar/abc123',
      method: 'GET',
    })

    const callUrl = (globalThis.fetch as any).mock.calls[0][0]
    expect(callUrl).toBe('/_profiler/api/toolbar/abc123')
  })

  it('does not apply slave prefix to /api/events/ URLs', async () => {
    mockGetActiveSlavePrefix.mockReturnValue('/slaves/node1')
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ events: [] }),
      } as any),
    )

    await apiFetch({
      url: '/_profiler/api/events/abc123',
      method: 'GET',
    })

    const callUrl = (globalThis.fetch as any).mock.calls[0][0]
    expect(callUrl).toBe('/_profiler/api/events/abc123')
  })

  it('applies slave prefix to other API URLs when a slave is selected', async () => {
    mockGetActiveSlavePrefix.mockReturnValue('/slaves/node1')
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ data: {} }),
      } as any),
    )

    await apiFetch({
      url: '/_profiler/api/profile/abc123',
      method: 'GET',
    })

    const callUrl = (globalThis.fetch as any).mock.calls[0][0]
    expect(callUrl).toBe('/_profiler/api/slaves/node1/profile/abc123')
  })

  it('does not apply any prefix when no slave is selected', async () => {
    mockGetActiveSlavePrefix.mockReturnValue('')
    globalThis.fetch = vi.fn(() =>
      Promise.resolve({
        ok: true,
        status: 200,
        json: () => Promise.resolve({ data: {} }),
      } as any),
    )

    await apiFetch({
      url: '/_profiler/api/profile/abc123',
      method: 'GET',
    })

    const callUrl = (globalThis.fetch as any).mock.calls[0][0]
    expect(callUrl).toBe('/_profiler/api/profile/abc123')
  })
})
