import { afterEach, describe, expect, it, vi } from 'vitest'
import { storageGet, storageSet } from '../../app/assets/typescript/profiler/storage'

afterEach(() => vi.unstubAllGlobals())

describe('storage', () => {
  it('reads and writes localStorage when it is available', () => {
    storageSet('k-ok', 'v')
    expect(localStorage.getItem('k-ok')).toBe('v')
    expect(storageGet('k-ok')).toBe('v')
  })

  it('does not throw and keeps the value in memory when localStorage is refused', () => {
    const refuse = () => { throw new DOMException('denied', 'SecurityError') }
    vi.stubGlobal('localStorage', { getItem: refuse, setItem: refuse })
    expect(storageGet('k-denied')).toBeNull()
    expect(() => storageSet('k-denied', 'x')).not.toThrow()
    expect(storageGet('k-denied')).toBe('x')
  })
})
