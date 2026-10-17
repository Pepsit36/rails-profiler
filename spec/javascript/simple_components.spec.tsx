import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render } from 'preact'
import { act } from 'preact/test-utils'
import { CachePanel } from '../../app/assets/typescript/profiler/components/toolbar/panels/CachePanel'
import { TestTab } from '../../app/assets/typescript/profiler/components/dashboard/tabs/TestTab'

let host: HTMLElement
beforeEach(() => {
  host = document.createElement('div')
  document.body.appendChild(host)
})
afterEach(() => {
  render(null, host)
  host.remove()
})

describe('CachePanel', () => {
  it('shows the hit rate and the counters', async () => {
    const cacheData = { hit_rate: 75, total_reads: 8, total_writes: 2, hits: 6, misses: 2 } as any
    await act(() => render(<CachePanel cacheData={cacheData} />, host))
    expect(host.textContent).toContain('Hit rate: 75%')
    const values = [...host.querySelectorAll('strong')].map(n => n.textContent)
    expect(values).toEqual(['8', '2', '6', '2'])
  })
})

describe('TestTab', () => {
  const base = { test_name: 'adds', test_file: 'spec/a_spec.rb', test_line: 4, framework: 'rspec' }

  it.each([
    ['passed', 'badge-success'],
    ['failed', 'badge-error'],
    ['pending', 'badge-warning'],
    ['weird', 'badge-default'],
  ])('renders the %s status with %s', async (status, cls) => {
    await act(() => render(<TestTab testData={{ ...base, status } as any} />, host))
    expect(host.querySelector(`.${cls}`)).not.toBeNull()
  })

  it('shows the optional rows only when the data has them', async () => {
    await act(() => render(<TestTab testData={{ ...base, status: 'failed' } as any} />, host))
    expect(host.textContent).not.toContain('Exception')
    await act(() => render(
      <TestTab testData={{ ...base, status: 'failed', assertions: 3, skip_reason: 'slow', exception_message: 'boom' } as any} />, host))
    expect(host.textContent).toContain('Assertions')
    expect(host.textContent).toContain('slow')
    expect(host.textContent).toContain('boom')
  })
})
