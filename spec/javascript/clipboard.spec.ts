import { afterEach, describe, expect, it, vi } from 'vitest'
import { copyText } from '../../app/assets/typescript/profiler/clipboard'

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

function stubClipboard(value: unknown) {
  Object.defineProperty(navigator, 'clipboard', { value, configurable: true })
}

describe('copyText', () => {
  it('uses navigator.clipboard when it is there', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    stubClipboard({ writeText })
    expect(await copyText('abc')).toBe(true)
    expect(writeText).toHaveBeenCalledWith('abc')
  })

  it('falls back to execCommand when the page is not a secure context', async () => {
    stubClipboard(undefined)
    let copied = ''
    document.execCommand = vi.fn(() => {
      copied = document.querySelector('textarea')?.value ?? ''
      return true
    })
    const area = vi.spyOn(document, 'createElement')
    expect(await copyText('abc')).toBe(true)
    expect(document.execCommand).toHaveBeenCalledWith('copy')
    expect(area).toHaveBeenCalledWith('textarea')
    expect(copied).toBe('abc')
    expect(document.querySelector('textarea')).toBeNull()
  })

  it('falls back when navigator.clipboard refuses', async () => {
    stubClipboard({ writeText: vi.fn().mockRejectedValue(new Error('denied')) })
    document.execCommand = vi.fn(() => true)
    expect(await copyText('abc')).toBe(true)
  })

  it('resolves to false when nothing can copy', async () => {
    stubClipboard(undefined)
    document.execCommand = vi.fn(() => false)
    expect(await copyText('abc')).toBe(false)
    document.execCommand = vi.fn(() => { throw new Error('nope') })
    expect(await copyText('abc')).toBe(false)
  })
})
