// localStorage that never throws. Browsers refuse it in some privacy modes and some policies
// disable it, and the accessor itself can throw. The values are then kept in memory for the
// life of the page: nothing persists, but the toolbar still renders and works.
const memory = new Map<string, string>()

export function storageGet(key: string): string | null {
  try {
    return localStorage.getItem(key)
  } catch {
    return memory.has(key) ? memory.get(key)! : null
  }
}

export function storageSet(key: string, value: string): void {
  memory.set(key, value)
  try {
    localStorage.setItem(key, value)
  } catch {
    // Kept in memory only.
  }
}
