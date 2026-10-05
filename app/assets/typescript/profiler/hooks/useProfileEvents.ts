import { useEffect, useRef } from 'preact/hooks'
import { apiFetch } from '../api-fetcher'
import { startProfileUpdatePoller, type ProfileEventsAnswer } from './profileUpdatePoller'

const BASE = '/_profiler'

/**
 * Calls onUpdate when the profile of +token+ is saved again after the version +cursor+, which
 * the toolbar data carries (events_cursor). Checks with short requests the server answers at
 * once, on the schedule of profileUpdatePoller, and not while the tab is hidden.
 */
export function useProfileEvents(
  token: string | undefined,
  cursor: number | undefined,
  onUpdate: () => void
): void {
  const onUpdateRef = useRef(onUpdate)
  onUpdateRef.current = onUpdate
  const ready = cursor !== undefined

  useEffect(() => {
    if (!token || cursor === undefined) return

    const poller = startProfileUpdatePoller({
      cursor,
      check: since => apiFetch<ProfileEventsAnswer>({
        url: `${BASE}/api/events/${encodeURIComponent(token)}`,
        method: 'GET',
        params: { since },
      }),
      onUpdate: () => onUpdateRef.current(),
    })

    const onVisibilityChange = () => {
      if (document.hidden) poller.pause()
      else poller.resume()
    }
    document.addEventListener('visibilitychange', onVisibilityChange)
    if (document.hidden) poller.pause()

    return () => {
      document.removeEventListener('visibilitychange', onVisibilityChange)
      poller.stop()
    }
    // Started once per token, from the first version the toolbar data gave.
  }, [token, ready])
}
