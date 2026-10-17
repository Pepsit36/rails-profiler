import { describe, expect, it } from 'vitest'
import { isToggleShortcut } from '../../app/assets/typescript/profiler/shortcut'

const keydown = (init: KeyboardEventInit) => new KeyboardEvent('keydown', init)

describe('isToggleShortcut', () => {
  it('matches Alt+P on the physical key', () => {
    expect(isToggleShortcut(keydown({ altKey: true, code: 'KeyP', key: 'p' }))).toBe(true)
  })

  it('matches on macOS, where Option+P produces a pi sign instead of "p"', () => {
    expect(isToggleShortcut(keydown({ altKey: true, code: 'KeyP', key: 'π' }))).toBe(true)
  })

  it('ignores other keys, a missing Alt and other modifiers', () => {
    expect(isToggleShortcut(keydown({ altKey: true, code: 'KeyO', key: 'o' }))).toBe(false)
    expect(isToggleShortcut(keydown({ code: 'KeyP', key: 'p' }))).toBe(false)
    expect(isToggleShortcut(keydown({ altKey: true, ctrlKey: true, code: 'KeyP' }))).toBe(false)
    expect(isToggleShortcut(keydown({ altKey: true, metaKey: true, code: 'KeyP' }))).toBe(false)
  })
})
