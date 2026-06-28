import { useState, useEffect, useRef } from 'preact/hooks'

const BASE = '/_profiler'

/**
 * Opens an SSE connection to receive profile update notifications.
 * Falls back to a polling interval when the SSE connection fails.
 */
export function useProfileEvents(
  token: string | undefined,
  collectors: string[],
  onUpdate: () => void
): { connected: boolean } {
  const [connected, setConnected] = useState(false)
  const fallbackRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    if (!token) return

    const clearFallback = () => {
      if (fallbackRef.current !== null) {
        clearInterval(fallbackRef.current)
        fallbackRef.current = null
      }
    }

    const params = new URLSearchParams()
    collectors.forEach(c => params.append('collectors[]', c))
    const url = `${BASE}/api/events/${token}?${params.toString()}`

    const es = new EventSource(url)

    es.addEventListener('profile_update', () => {
      onUpdate()
    })

    es.onopen = () => {
      setConnected(true)
      clearFallback()
    }

    es.onerror = () => {
      es.close()
      setConnected(false)
      if (fallbackRef.current === null) {
        fallbackRef.current = setInterval(() => onUpdate(), 10_000)
      }
    }

    return () => {
      es.close()
      clearFallback()
    }
  }, [token])

  return { connected }
}
