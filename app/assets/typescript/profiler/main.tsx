import { render } from 'preact'
import { ProfileList } from './components/ProfileList'
import { ProfileDashboard } from './components/dashboard/ProfileDashboard'
import { initTimeline } from './timeline'
import { formatSQL } from './sql-formatter'
import { themeManager, createThemeToggle } from './theme'

document.addEventListener('DOMContentLoaded', () => {
  const indexEl = document.getElementById('profiler-index')
  if (indexEl) {
    render(<ProfileList />, indexEl)
  }

  const showEl = document.getElementById('profiler-show')
  if (showEl) {
    const dataEl = document.getElementById('profiler-show-data')
    if (dataEl) {
      const profile = JSON.parse(dataEl.textContent!)
      const tab = new URLSearchParams(location.search).get('tab') || 'request'
      const embedded = showEl.dataset.embedded === 'true'
      render(<ProfileDashboard profile={profile} initialTab={tab as any} embedded={embedded} />, showEl)
    }
  }

  if (!indexEl && !showEl) {
    const header = document.querySelector('.header, .profiler-detail') as HTMLElement | null
    if (header) {
      const toggle = createThemeToggle()
      toggle.style.position = 'absolute'
      toggle.style.top = '20px'
      toggle.style.right = '20px'
      header.style.position = 'relative'
      header.appendChild(toggle)
    }
  }

  const timeline = document.getElementById('profiler-timeline')
  if (timeline) {
    initTimeline(timeline)
  }

  document.querySelectorAll('pre[data-language="sql"]').forEach((block) => {
    formatSQL(block as HTMLElement)
  })
})

export { initTimeline, formatSQL, themeManager, createThemeToggle }
