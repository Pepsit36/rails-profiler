import { MailerData } from '../../../dashboard/types'

interface Props {
  mailerData: MailerData
}

export function MailerPanel({ mailerData }: Props) {
  const hasErrors = mailerData.failed > 0 || mailerData.loop_warnings.length > 0

  return (
    <>
      <div class="profiler-toolbar-panel-header">
        Mailers
        <span class="profiler-float-right">{mailerData.total} email{mailerData.total !== 1 ? 's' : ''}</span>
      </div>
      <div class="profiler-toolbar-panel-content">
        {mailerData.deliver_now > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span>deliver_now</span>
            <strong>{mailerData.deliver_now}</strong>
          </div>
        )}
        {mailerData.deliver_later > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span>deliver_later</span>
            <strong>{mailerData.deliver_later}</strong>
          </div>
        )}
        {mailerData.multi_part_count > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span>Multi-part</span>
            <strong>{mailerData.multi_part_count}</strong>
          </div>
        )}
        {mailerData.failed > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span>Errors</span>
            <strong class="profiler-text--error">{mailerData.failed}</strong>
          </div>
        )}
        {mailerData.loop_warnings.length > 0 && (
          <div class="profiler-toolbar-panel-row">
            <span class="profiler-text--warning">⚠️ Loop detected</span>
            <strong class="profiler-text--warning">{mailerData.loop_warnings.length}</strong>
          </div>
        )}
        {[...mailerData.emails, ...mailerData.errors].slice(0, 3).map((email, i) => (
          <div key={i} class="profiler-toolbar-panel-row profiler-text--sm">
            <span class="profiler-text--muted">
              {email.mailer_class}#{email.action}
            </span>
            <span class={email.error ? 'profiler-text--error' : 'profiler-text--success'}>
              {email.error ? '❌' : '✅'}
            </span>
          </div>
        ))}
        {mailerData.total > 3 && (
          <div class="profiler-toolbar-panel-row profiler-text--muted profiler-text--xs">
            +{mailerData.total - 3} more…
          </div>
        )}
      </div>
    </>
  )
}
