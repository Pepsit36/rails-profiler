import { render } from 'preact'
import { useEffect } from 'preact/hooks'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ToolbarApp } from './components/toolbar/ToolbarApp'
import { useGetToolbar } from './generated/api'

declare global {
  interface Window {
    __PROFILER_PARENT_TOKEN__?: string
    __PROFILER_INTERCEPTOR_ACTIVE__?: boolean
    __PROFILER_REFRESH_TOOLBAR__?: () => void
  }
}

const ANIM_MS = 280

function applyTheme(elements: HTMLElement[]): void {
  const stored = localStorage.getItem('profiler-theme')
  const theme = stored === 'light' ? 'light'
    : stored === 'dark' ? 'dark'
    : (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')
  elements.forEach(el => el.setAttribute('data-theme', theme))
}

interface ToolbarMountProps {
  token: string
}

const toolbarQueryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 30_000, retry: 1 } },
})

function ToolbarMount({ token }: ToolbarMountProps) {
  const { data, refetch } = useGetToolbar(token, { query: { refetchOnWindowFocus: false } })

  useEffect(() => {
    window.__PROFILER_REFRESH_TOOLBAR__ = () => { refetch() }
  }, [refetch])

  const profile = data?.profile ?? null
  if (!profile) return null

  return <ToolbarApp profile={profile} token={token} />
}

function mountToolbar(): void {
  const el = document.getElementById('profiler-toolbar') as HTMLElement | null
  const toggleEl = document.getElementById('profiler-toolbar-toggle') as HTMLElement | null
  if (!el || !toggleEl) return

  const token = el.dataset.token
  if (!token) return

  const themeEls = [el, toggleEl]
  applyTheme(themeEls)

  window.addEventListener('storage', (e) => {
    if (e.key === 'profiler-theme') applyTheme(themeEls)
  })

  window.addEventListener('profiler:theme-change', ((e: CustomEvent) => {
    if (e.detail?.theme) themeEls.forEach(elem => elem.setAttribute('data-theme', e.detail.theme))
  }) as EventListener)

  let isCollapsed = localStorage.getItem('profiler-toolbar-collapsed') === 'true'

  // Sync toggle arrow to match current state
  toggleEl.dataset.collapsed = String(isCollapsed)

  // Fallback: if inline script didn't run (e.g. CSP blocked), hide toolbar now
  if (isCollapsed && !el.style.transform) {
    el.style.animation = 'none'
    el.style.transform = 'translateX(calc(100% + 44px))'
  }

  // After pfIn completes, clear its fill so translateX collapse works without conflict
  if (!isCollapsed) {
    setTimeout(() => { el.style.animation = 'none' }, 400)
  }

  function toggleCollapse(): void {
    const next = !isCollapsed
    isCollapsed = next
    localStorage.setItem('profiler-toolbar-collapsed', String(next))
    toggleEl.dataset.collapsed = String(next)

    if (next) {
      el.style.transition = `transform ${ANIM_MS}ms cubic-bezier(0.4,0,0.2,1)`
      el.style.transform = 'translateX(calc(100% + 44px))'
    } else {
      el.style.transition = 'none'
      el.style.transform = 'translateX(calc(100% + 44px))'
      void el.offsetWidth // force reflow so transition applies on next frame
      el.style.transition = `transform ${ANIM_MS}ms cubic-bezier(0.4,0,0.2,1)`
      el.style.transform = 'translateX(0)'
      setTimeout(() => {
        el.style.transform = ''
        el.style.transition = ''
      }, ANIM_MS + 50)
    }
  }

  toggleEl.addEventListener('click', toggleCollapse)

  document.addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.altKey && e.key === 'p') {
      e.preventDefault()
      toggleCollapse()
    }
  })

  render(
    <QueryClientProvider client={toolbarQueryClient}>
      <ToolbarMount token={token} />
    </QueryClientProvider>,
    el
  )
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', mountToolbar)
} else {
  mountToolbar()
}
