import type { ComponentChildren } from 'preact'
import { useEditorConfig } from '../hooks/useEditorConfig'
import { buildEditorUrl, parseFrame } from '../source-links'

interface Props {
  file: string
  line: number
  // What is displayed; defaults to "file:line".
  children?: ComponentChildren
  class?: string
}

// A file:line that opens in the editor. Without a safe URL (scheme not allowed, relative path,
// settings not loaded) it is the same text, not a link.
export function SourceLink({ file, line, children, class: className }: Props) {
  const settings = useEditorConfig()
  const content = children ?? `${file}:${line}`
  const editorUrl = buildEditorUrl(file, line, settings)

  if (!editorUrl) return <span class={className}>{content}</span>

  return (
    <a
      href={editorUrl}
      class={className}
      title={`Open ${file}:${line} in your editor`}
      rel="noopener noreferrer"
      data-source-link=""
      onClick={(e) => e.stopPropagation()}
    >
      {content}
    </a>
  )
}

// A backtrace line ("path:12:in `m'"): linked when it carries a path and a line, plain text otherwise.
export function SourceFrame({ frame, class: className }: { frame: string; class?: string }) {
  const parsed = parseFrame(frame)
  if (!parsed) return <span class={className}>{frame}</span>
  return (
    <SourceLink file={parsed.file} line={parsed.line} class={className}>
      {frame}
    </SourceLink>
  )
}
