import { ComponentChildren } from 'preact'
import { useState, useRef, useEffect } from 'preact/hooks'

interface Props {
  children: ComponentChildren
  panel?: ComponentChildren
  href?: string
  className?: string
  panelLarge?: boolean
}

export function ToolbarItem({ children, panel, href, className, panelLarge }: Props) {
  const [visible, setVisible] = useState(false)
  const panelRef = useRef<HTMLDivElement>(null)
  const showTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const hideTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const show = () => {
    if (hideTimer.current) { clearTimeout(hideTimer.current); hideTimer.current = null }
    showTimer.current = setTimeout(() => setVisible(true), 100)
  }

  const hide = () => {
    if (showTimer.current) { clearTimeout(showTimer.current); showTimer.current = null }
    hideTimer.current = setTimeout(() => setVisible(false), 150)
  }

  useEffect(() => {
    if (visible && panelRef.current) {
      const el = panelRef.current
      el.style.left = '50%'
      el.style.right = 'auto'
      el.style.transform = 'translateX(-50%)'
      const rect = el.getBoundingClientRect()
      if (rect.left < 8) {
        el.style.left = '0'
        el.style.transform = 'none'
      } else if (rect.right > window.innerWidth - 8) {
        el.style.left = 'auto'
        el.style.right = '0'
        el.style.transform = 'none'
      }
    }
  }, [visible])

  const cls = [
    'profiler-toolbar-item',
    panel ? 'profiler-toolbar-hoverable' : '',
    className || '',
  ].filter(Boolean).join(' ')

  const panelEl = panel ? (
    <div
      ref={panelRef}
      class={`profiler-toolbar-panel${panelLarge ? ' profiler-toolbar-panel-large' : ''}`}
      style={{ display: visible ? 'block' : 'none' }}
      onMouseEnter={show}
      onMouseLeave={hide}
    >
      {panel}
    </div>
  ) : null

  if (href) {
    return (
      <a href={href} class={cls} onMouseEnter={show} onMouseLeave={hide}>
        {children}
        {panelEl}
      </a>
    )
  }

  return (
    <span class={cls} onMouseEnter={show} onMouseLeave={hide}>
      {children}
      {panelEl}
    </span>
  )
}
