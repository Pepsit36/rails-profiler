import { I18nData, I18nLookup } from '../../../dashboard/types'

interface Props {
  i18nData: I18nData
}

export function I18nPanel({ i18nData }: Props) {
  const missing = i18nData.lookups.filter((l: I18nLookup) => l.missing)
  const ok = i18nData.lookups.filter((l: I18nLookup) => !l.missing)
  const prioritized = [...missing, ...ok].slice(0, 5)
  const remaining = i18nData.total - 5

  return (
    <>
      <div class="profiler-toolbar-panel-header">
        I18n
        <span style="margin-left:6px;font-weight:400;color:var(--profiler-muted,#6b7280);">[{i18nData.locale}]</span>
        {i18nData.missing_count > 0 && (
          <span style="color:var(--profiler-error,#ef4444);margin-left:8px;">
            {i18nData.missing_count} missing
          </span>
        )}
      </div>
      <div class="profiler-toolbar-panel-content">
        {prioritized.map((entry: I18nLookup, i: number) => (
          <div key={i} class="profiler-toolbar-panel-row" style="align-items:flex-start;gap:6px;">
            <span
              class="profiler-text--xs profiler-text--truncate"
              style={`flex:1;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;${entry.missing ? 'color:var(--profiler-error,#ef4444);' : ''}`}
            >
              {entry.key}
            </span>
            {entry.missing && (
              <span class="profiler-text--xs" style="color:var(--profiler-error,#ef4444);font-weight:600;">⚠</span>
            )}
          </div>
        ))}
        {remaining > 0 && (
          <div class="profiler-more">+ {remaining} more keys</div>
        )}
      </div>
    </>
  )
}
