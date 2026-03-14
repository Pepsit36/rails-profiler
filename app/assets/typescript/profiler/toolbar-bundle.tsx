import { render } from 'preact'
import { ToolbarApp } from './components/toolbar/ToolbarApp'
import type { Profile } from './dashboard/types'

declare global {
  interface Window {
    __PROFILER_PARENT_TOKEN__?: string
    __PROFILER_INTERCEPTOR_ACTIVE__?: boolean
    __PROFILER_REFRESH_TOOLBAR__?: () => void
  }
}

function applyTheme(el: HTMLElement): void {
  const stored = localStorage.getItem('profiler-theme')
  const theme = stored === 'light' ? 'light'
    : stored === 'dark' ? 'dark'
    : (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark')
  el.setAttribute('data-theme', theme)
}

function mountToolbar(): void {
  const el = document.getElementById('profiler-toolbar')
  if (!el) return

  const token = el.dataset.token
  if (!token) return

  applyTheme(el)

  window.addEventListener('storage', (e) => {
    if (e.key === 'profiler-theme') applyTheme(el)
  })

  window.addEventListener('profiler:theme-change', ((e: CustomEvent) => {
    if (e.detail?.theme) el.setAttribute('data-theme', e.detail.theme)
  }) as EventListener)

  const renderToolbar = (profile: Profile) => {
    render(<ToolbarApp profile={profile} token={token} />, el)
    applyTheme(el)
  }

  const loadAndRender = () => {
    fetch(`/_profiler/api/toolbar/${token}`)
      .then(res => res.json())
      .then(data => {
        if (data.profile) renderToolbar(data.profile as Profile)
      })
      .catch(err => console.debug('Profiler toolbar load failed:', err))
  }

  window.__PROFILER_REFRESH_TOOLBAR__ = loadAndRender

  loadAndRender()

  document.addEventListener('keydown', (e: KeyboardEvent) => {
    if (e.altKey && e.key === 'p') {
      e.preventDefault()
      const hidden = el.dataset.hidden === 'true'
      if (hidden) {
        el.dataset.hidden = 'false'
        el.style.transform = 'translateY(0)'
        el.style.opacity = '1'
        localStorage.setItem('profiler-toolbar-hidden', 'false')
      } else {
        el.dataset.hidden = 'true'
        el.style.transform = 'translateY(100%)'
        el.style.opacity = '0'
        localStorage.setItem('profiler-toolbar-hidden', 'true')
      }
    }
    if (e.key === 'Escape') {
      el.dataset.hidden = 'true'
      el.style.transform = 'translateY(100%)'
      el.style.opacity = '0'
    }
  })

  const hidden = localStorage.getItem('profiler-toolbar-hidden') === 'true'
  if (hidden) {
    el.dataset.hidden = 'true'
    el.style.transform = 'translateY(100%)'
    el.style.opacity = '0'
  }
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', mountToolbar)
} else {
  mountToolbar()
}
