import { useEffect, useRef } from 'preact/hooks'
import { TestRun } from '../../../dashboard/types'

interface Props {
  run: TestRun | null
}

function statusColor(status: string): string {
  if (status === 'passed')  return 'var(--profiler-success, #10b981)'
  if (status === 'failed')  return 'var(--profiler-error, #ef4444)'
  if (status === 'running') return 'var(--profiler-accent, #06b6d4)'
  if (status === 'killed' || status === 'error') return 'var(--profiler-warning, #f59e0b)'
  return 'var(--profiler-text-muted, #888)'
}

function statusLabel(status: string): string {
  const map: Record<string, string> = {
    pending: '⏳ Pending',
    running: '● Running…',
    passed:  '✓ Passed',
    failed:  '✗ Failed',
    killed:  '■ Killed',
    error:   '⚠ Error',
  }
  return map[status] || status
}

interface AnsiSpan {
  text: string
  style: string
}

// Parse ANSI escape codes into safe text/style pairs for Preact rendering.
// Only a fixed set of ANSI color codes are recognized; the text is rendered as
// text nodes — no HTML injection risk.
function parseAnsi(raw: string): AnsiSpan[] {
  const ANSI_STYLES: Record<string, string> = {
    '0':  '',
    '1':  'font-weight:bold',
    '31': 'color:var(--ansi-red)',
    '32': 'color:var(--ansi-green)',
    '33': 'color:var(--ansi-yellow)',
    '34': 'color:var(--ansi-blue)',
    '35': 'color:var(--ansi-purple)',
    '36': 'color:var(--ansi-cyan)',
  }

  const spans: AnsiSpan[] = []
  let currentStyle = ''

  // Split on ANSI escape sequences
  const parts = raw.split(/(\x1b\[[0-9;]*m)/)
  for (const part of parts) {
    if (part.startsWith('\x1b[') && part.endsWith('m')) {
      // It's a control sequence — update current style
      const codes = part.slice(2, -1).split(';')
      if (codes.includes('0')) {
        currentStyle = ''
      } else {
        const styles = codes.map(c => ANSI_STYLES[c] ?? '').filter(Boolean)
        currentStyle = [...(currentStyle ? [currentStyle] : []), ...styles].join(';')
      }
    } else if (part.length > 0) {
      spans.push({ text: part, style: currentStyle })
    }
  }

  return spans
}

function AnsiOutput({ text }: { text: string }) {
  const spans = parseAnsi(text)
  if (spans.length === 0) {
    return <span style="color:var(--profiler-text-muted)">No output yet…</span>
  }
  return (
    <>
      {spans.map((s, i) =>
        s.style
          ? <span key={i} style={s.style}>{s.text}</span>
          : <span key={i}>{s.text}</span>
      )}
    </>
  )
}

export function RunOutput({ run }: Props) {
  const outputRef = useRef<HTMLPreElement>(null)

  useEffect(() => {
    if (outputRef.current && run?.status === 'running') {
      outputRef.current.scrollTop = outputRef.current.scrollHeight
    }
  }, [run?.output])

  if (!run) {
    return (
      <div class="profiler-empty" style="height: 100%; display: flex; align-items: center; justify-content: center">
        <div>
          <div class="profiler-empty__title" style="font-size: 1.1rem">Select files and click Run</div>
          <p class="profiler-empty__description">Test output will appear here in real time</p>
        </div>
      </div>
    )
  }

  return (
    <div style="display: flex; flex-direction: column; height: 100%; gap: 12px">
      <div style="display: flex; align-items: center; gap: 12px; flex-shrink: 0">
        <span style={`font-weight: 600; color: ${statusColor(run.status)}`}>
          {statusLabel(run.status)}
        </span>
        {run.duration != null && (
          <span class="profiler-text--xs profiler-text--muted">{(run.duration / 1000).toFixed(1)}s</span>
        )}
        {(run.status === 'passed' || run.status === 'failed') && (
          <a href="/_profiler?section=tests" class="profiler-text--xs" style="color: var(--profiler-accent, #06b6d4); margin-left: auto">
            View in Profiler →
          </a>
        )}
      </div>

      <pre
        ref={outputRef}
        style="flex: 1; overflow-y: auto; background: var(--profiler-terminal-bg); color: var(--profiler-terminal-text); padding: 14px 16px; border-radius: 6px; font-family: var(--profiler-font-mono); font-size: 12px; line-height: 1.65; margin: 0; white-space: pre-wrap; word-break: break-all; border: 1px solid var(--profiler-border)"
      >
        <AnsiOutput text={run.output || ''} />
      </pre>

      {run.files.length > 0 && (
        <div class="profiler-text--xs profiler-text--muted" style="flex-shrink: 0">
          {run.files.length} file{run.files.length !== 1 ? 's' : ''} · {run.framework}
        </div>
      )}
    </div>
  )
}
