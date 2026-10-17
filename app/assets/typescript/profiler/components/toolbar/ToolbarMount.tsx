import { useEffect } from 'preact/hooks'
import { ToolbarApp } from './ToolbarApp'
import { useGetToolbar } from '../../generated/api'
import { useProfileEvents } from '../../hooks/useProfileEvents'

interface Props {
  token: string
}

// Loads the profile that feeds the toolbar. When it cannot be loaded (network error, 500,
// timeout) and there is nothing to show yet, says so and offers to try again, rather than
// leaving an empty bar nobody can explain.
export function ToolbarMount({ token }: Props) {
  const { data, refetch, isError, isFetching } = useGetToolbar(token, { query: { refetchOnWindowFocus: false } } as any)

  useEffect(() => {
    window.__PROFILER_REFRESH_TOOLBAR__ = () => { refetch() }
  }, [refetch])

  useProfileEvents(token, data?.events_cursor, () => { refetch() })

  const profile = data?.profile ?? null
  if (profile) return <ToolbarApp profile={profile} token={token} />

  if (isError) {
    return (
      <div class="profiler-toolbar-container">
        <span class="profiler-toolbar-error" role="alert">
          <span class="profiler-text--error">Profiler data could not be loaded.</span>
          <button type="button" class="profiler-toolbar-retry" disabled={isFetching} onClick={() => { refetch() }}>
            {isFetching ? 'Retrying...' : 'Retry'}
          </button>
        </span>
      </div>
    )
  }

  return null
}
