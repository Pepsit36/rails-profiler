// Asks the server, now and then, whether a profile was saved again since the version the page
// holds. Each question is answered at once (GET /_profiler/api/events/:token?since=), so no
// server thread is held however many pages are open; the cost is one small request per check.
//
// Saves after the page come from work that ends shortly after it (an outgoing HTTP request in a
// background thread, for instance), so checks start often and slow down: 10 in the first minute,
// then 2 a minute, none while the tab is hidden, and none at all after GIVE_UP_AFTER_MS without
// a save. A save found starts the schedule again; a failed check waits like any other.

export const POLL_DELAYS_MS = [1000, 1000, 2000, 2000, 4000, 4000, 8000, 8000, 15000, 15000]
export const STEADY_DELAY_MS = 30_000
export const GIVE_UP_AFTER_MS = 10 * 60_000

export interface ProfileEventsAnswer {
  cursor: number
  updated: boolean
}

export interface PollerOptions {
  cursor: number
  check: (since: number) => Promise<ProfileEventsAnswer>
  onUpdate: () => void
  now?: () => number
  setTimer?: (fn: () => void, ms: number) => unknown
  clearTimer?: (timer: unknown) => void
}

export interface Poller {
  // Stops checking until resume, as for a hidden tab.
  pause(): void
  // Checks at once, then follows the schedule; past the give-up delay, only that check.
  resume(): void
  stop(): void
}

export function startProfileUpdatePoller(options: PollerOptions): Poller {
  const now = options.now ?? (() => Date.now())
  const setTimer = options.setTimer ?? ((fn, ms) => setTimeout(fn, ms))
  const clearTimer = options.clearTimer ?? (timer => clearTimeout(timer as ReturnType<typeof setTimeout>))

  let cursor = options.cursor
  let step = 0
  let lastSaveAt = now()
  let timer: unknown = null
  let paused = false
  let stopped = false
  let inFlight = false

  const cancelTimer = () => {
    if (timer !== null) {
      clearTimer(timer)
      timer = null
    }
  }

  const scheduleNext = () => {
    cancelTimer()
    if (stopped || paused) return
    if (now() - lastSaveAt >= GIVE_UP_AFTER_MS) return

    const delay = step < POLL_DELAYS_MS.length ? POLL_DELAYS_MS[step] : STEADY_DELAY_MS
    step += 1
    timer = setTimer(() => { timer = null; void checkNow() }, delay)
  }

  const checkNow = async () => {
    if (stopped || inFlight) return
    inFlight = true
    try {
      const answer = await options.check(cursor)
      if (stopped) return
      cursor = Math.max(cursor, answer.cursor)
      if (answer.updated) {
        step = 0
        lastSaveAt = now()
        options.onUpdate()
      }
    } catch {
      // A failed check counts as one: the next waits as long as planned, never less.
    } finally {
      inFlight = false
    }
    scheduleNext()
  }

  scheduleNext()

  return {
    pause() {
      paused = true
      cancelTimer()
    },
    resume() {
      if (stopped) return
      paused = false
      cancelTimer()
      void checkNow()
    },
    stop() {
      stopped = true
      cancelTimer()
    },
  }
}
