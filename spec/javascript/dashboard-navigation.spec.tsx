import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { deduplicateByToken } from '../../app/assets/typescript/profiler/dashboard/utils'
import { ProfileDashboard } from '../../app/assets/typescript/profiler/components/dashboard/ProfileDashboard'
import { JobProfileDashboard } from '../../app/assets/typescript/profiler/components/dashboard/JobProfileDashboard'

let host: HTMLElement
beforeEach(() => {
  host = document.createElement('div')
  document.body.appendChild(host)
  window.history.replaceState(null, '', '/_profiler/abc')
})
afterEach(() => {
  render(null, host)
  host.remove()
  vi.restoreAllMocks()
})

const withQuery = (query: string) => window.history.replaceState(null, '', `/_profiler/abc${query}`)
const activeTab = () => host.querySelector('.tab.active')?.textContent ?? null

const baseProfile = (collectors: Record<string, unknown> = {}) => ({
  token: 'abc',
  method: 'GET',
  path: '/',
  status: 200,
  duration: 12.3,
  started_at: '2026-01-01T00:00:00Z',
  collectors_data: collectors,
}) as any

const withException = { exception: { exception_class: 'RuntimeError', message: 'boom' } }

describe('deduplicateByToken', () => {
  it('keeps the first occurrence of each token and preserves order', () => {
    const items = [
      { token: 'a', n: 1 },
      { token: 'b', n: 2 },
      { token: 'a', n: 3 },
      { token: 'c', n: 4 },
      { token: 'b', n: 5 },
    ]
    expect(deduplicateByToken(items)).toEqual([
      { token: 'a', n: 1 },
      { token: 'b', n: 2 },
      { token: 'c', n: 4 },
    ])
  })

  it('returns an empty list for an empty input', () => {
    expect(deduplicateByToken([])).toEqual([])
  })
})

describe.each([
  ['ProfileDashboard', (p: any) => <ProfileDashboard profile={p} initialTab="request" embedded={false} />, 'Request', 'Request'],
  ['JobProfileDashboard', (p: any) => <JobProfileDashboard profile={p} initialTab="job" embedded={false} />, 'Job', 'Job'],
])('%s', (_name, view, defaultLabel) => {
  const mount = async (profile: any) => { await act(() => render(<QueryClientProvider client={new QueryClient()}>{view(profile)}</QueryClientProvider>, host)) }
  const tabByText = (re: RegExp) =>
    Array.from(host.querySelectorAll<HTMLAnchorElement>('.tabs a')).find(a => re.test(a.textContent ?? ''))!

  it('opens the tab named by ?tab= even when the profile has an exception', async () => {
    withQuery('?tab=database')
    await mount(baseProfile(withException))
    expect(activeTab()).toBe('Database')
  })

  it('falls back to the exception tab when ?tab= is unknown', async () => {
    withQuery('?tab=bogus')
    await mount(baseProfile(withException))
    expect(activeTab()).toContain('Exception')
  })

  it('falls back to the default tab when ?tab= is unknown and there is no exception', async () => {
    withQuery('?tab=bogus')
    await mount(baseProfile())
    expect(activeTab()).toContain(defaultLabel)
  })

  it('opens the exception tab by default when the profile has an exception', async () => {
    await mount(baseProfile(withException))
    expect(activeTab()).toContain('Exception')
  })

  it('updates the URL with replaceState, never pushState, when a tab is clicked', async () => {
    const replace = vi.spyOn(window.history, 'replaceState')
    const push = vi.spyOn(window.history, 'pushState')
    await mount(baseProfile())
    await act(() => { tabByText(/^Database$/).click() })
    expect(push).not.toHaveBeenCalled()
    expect(replace).toHaveBeenCalledTimes(1)
    expect(window.location.search).toBe('?tab=database')
    expect(activeTab()).toBe('Database')
  })

  it('shows the version mismatch banner in English', async () => {
    const meta = document.createElement('meta')
    meta.name = 'profiler-version'
    meta.content = '2.0.0'
    document.head.appendChild(meta)
    try {
      await mount({ ...baseProfile(), gem_version: '1.0.0' })
      const banner = host.querySelector('.profiler-version-mismatch')!.textContent!
      expect(banner).toContain('Profile captured with version 1.0.0, current version: 2.0.0')
    } finally {
      meta.remove()
    }
  })
})
