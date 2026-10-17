// Copies text to the clipboard. navigator.clipboard only exists in a secure context (HTTPS or
// localhost): a page served over plain HTTP from another address, an internal network for
// instance, has no such API. Falls back to a selected, off-screen <textarea> and
// document.execCommand('copy'), deprecated but still supported by every browser. Resolves to
// false when neither works, so that the caller can tell the user.
export async function copyText(text: string): Promise<boolean> {
  if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // Permission denied or document not focused: try the fallback.
    }
  }
  return copyWithSelection(text)
}

function copyWithSelection(text: string): boolean {
  if (typeof document === 'undefined' || typeof document.execCommand !== 'function') return false

  const area = document.createElement('textarea')
  area.value = text
  area.setAttribute('readonly', '')
  area.setAttribute('aria-hidden', 'true')
  area.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;opacity:0;pointer-events:none'
  const previousFocus = document.activeElement as HTMLElement | null
  document.body.appendChild(area)
  try {
    area.select()
    area.setSelectionRange(0, text.length)
    return document.execCommand('copy')
  } catch {
    return false
  } finally {
    document.body.removeChild(area)
    previousFocus?.focus?.()
  }
}
