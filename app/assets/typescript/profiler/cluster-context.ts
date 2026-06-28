const STORAGE_KEY = 'profiler-active-slave'

// Initialize from sessionStorage so the choice survives page navigations
// but not new browser sessions (which is fine for dev use)
let activeSlavePrefix = (() => {
  try {
    const stored = sessionStorage.getItem(STORAGE_KEY)
    return stored ? `/slaves/${stored}` : ''
  } catch {
    return ''
  }
})()

export function getActiveSlavePrefix(): string {
  return activeSlavePrefix
}

export function getActiveSlaveName(): string | null {
  if (!activeSlavePrefix) return null
  return activeSlavePrefix.replace('/slaves/', '')
}

export function setActiveSlave(name: string | null): void {
  try {
    if (name) {
      sessionStorage.setItem(STORAGE_KEY, name)
    } else {
      sessionStorage.removeItem(STORAGE_KEY)
    }
  } catch {
    // sessionStorage unavailable — still set the in-memory value
  }
  activeSlavePrefix = name ? `/slaves/${name}` : ''
  // Reload so react-query fetches fresh data with the new prefix
  window.location.reload()
}
