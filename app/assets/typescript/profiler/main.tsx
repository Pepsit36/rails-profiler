import { render } from 'preact'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ProfileList } from './components/ProfileList'
import { ProfilerSelector } from './components/ProfilerSelector'
import { ProfileDashboard } from './components/dashboard/ProfileDashboard'
import { JobProfileDashboard } from './components/dashboard/JobProfileDashboard'
import { ConsoleProfileDashboard } from './components/dashboard/ConsoleProfileDashboard'
import { TestProfileDashboard } from './components/dashboard/TestProfileDashboard'
import { TestRunnerPage } from './components/test-runner/TestRunnerPage'
import { initTimeline } from './timeline'
import { formatSQL } from './sql-formatter'
import { themeManager, createThemeToggle } from './theme'

const queryClient = new QueryClient({
  defaultOptions: { queries: { staleTime: 30_000, retry: 1 } },
})

document.addEventListener('DOMContentLoaded', () => {
  const selectorEl = document.getElementById('profiler-cluster-selector')
  const isMaster = document.querySelector('meta[name="profiler-is-master"]')?.getAttribute('content') === 'true'
  if (selectorEl && isMaster) {
    render(
      <QueryClientProvider client={queryClient}>
        <ProfilerSelector />
      </QueryClientProvider>,
      selectorEl
    )
  }

  const indexEl = document.getElementById('profiler-index')
  if (indexEl) {
    render(
      <QueryClientProvider client={queryClient}>
        <ProfileList />
      </QueryClientProvider>,
      indexEl
    )
  }

  const showEl = document.getElementById('profiler-show')
  if (showEl) {
    const dataEl = document.getElementById('profiler-show-data')
    if (dataEl) {
      const profile = JSON.parse(dataEl.textContent!)
      const tab = new URLSearchParams(location.search).get('tab') || 'request'
      const embedded = showEl.dataset.embedded === 'true'
      if (profile.profile_type === 'job') {
        render(<JobProfileDashboard profile={profile} initialTab={tab} embedded={embedded} />, showEl)
      } else if (profile.profile_type === 'console') {
        render(<ConsoleProfileDashboard profile={profile} initialTab={tab} embedded={embedded} />, showEl)
      } else if (profile.profile_type === 'test') {
        render(<TestProfileDashboard profile={profile} initialTab={tab} embedded={embedded} />, showEl)
      } else {
        render(<ProfileDashboard profile={profile} initialTab={tab as any} embedded={embedded} />, showEl)
      }
    }
  }

  const testRunnerEl = document.getElementById('profiler-test-runner')
  if (testRunnerEl) {
    render(<TestRunnerPage />, testRunnerEl)
  }

  if (!indexEl && !showEl && !testRunnerEl) {
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
