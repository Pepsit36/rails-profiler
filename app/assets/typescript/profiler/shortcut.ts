// The keyboard shortcut that shows and hides the toolbar: Alt+P (Option+P on macOS). Matched on
// the physical key, event.code, not on the character it produces: Option+P types a special
// character on macOS (a pi sign), so event.key is never "p" there, and other layouts put
// other letters on that key.
export function isToggleShortcut(e: Pick<KeyboardEvent, 'altKey' | 'ctrlKey' | 'metaKey' | 'shiftKey' | 'code'>): boolean {
  return e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey && e.code === 'KeyP'
}
