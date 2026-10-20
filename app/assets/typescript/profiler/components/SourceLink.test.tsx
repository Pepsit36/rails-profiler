import { cleanup, render, screen } from '@testing-library/preact'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DumpsTab } from './dashboard/tabs/DumpsTab'
import { ExceptionTab } from './dashboard/tabs/ExceptionTab'
import { SourceFrame, SourceLink } from './SourceLink'

const settings = vi.hoisted(() => ({ current: { scheme: 'vscode', pathMap: {} } as Record<string, unknown> }))
vi.mock('../hooks/useEditorConfig', () => ({ useEditorConfig: () => settings.current }))

afterEach(cleanup)

beforeEach(() => {
  settings.current = { scheme: 'vscode', pathMap: { '/app': '/home/me/projet' } }
})

describe('SourceLink', () => {
  it('renders a link to the editor, with the container path translated', () => {
    render(<SourceLink file="/app/models/user.rb" line={12} />)
    const link = screen.getByText('/app/models/user.rb:12') as HTMLAnchorElement
    expect(link.tagName).toBe('A')
    expect(link.getAttribute('href')).toBe('vscode://file/home/me/projet/models/user.rb:12')
  })

  it('renders plain text for a scheme outside the allow list', () => {
    settings.current = { scheme: 'javascript', pathMap: {} }
    render(<SourceLink file="/app/a.rb" line={1} />)
    expect(screen.getByText('/app/a.rb:1').tagName).toBe('SPAN')
    expect(document.querySelector('a')).toBeNull()
  })

  it('renders plain text while the settings are not loaded', () => {
    settings.current = { scheme: null, pathMap: {} }
    render(<SourceLink file="/app/a.rb" line={1} />)
    expect(document.querySelector('a')).toBeNull()
  })

  it('links a backtrace frame and keeps its text', () => {
    render(<SourceFrame frame="/app/a.rb:9:in `run'" />)
    const link = document.querySelector('a') as HTMLAnchorElement
    expect(link.getAttribute('href')).toBe('vscode://file/home/me/projet/a.rb:9')
    expect(link.textContent).toBe("/app/a.rb:9:in `run'")
  })

  it('leaves a frame without a line as text', () => {
    render(<SourceFrame frame="(eval)" />)
    expect(document.querySelector('a')).toBeNull()
  })
})

describe('tab integration', () => {
  it('links the location of a dump', () => {
    const dumpData = {
      count: 1,
      dumps: [{ file: '/app/controllers/x.rb', line: 4, label: 'v', formatted: '1', timestamp: '2026-01-01T00:00:00Z' }],
    } as never
    render(<DumpsTab dumpData={dumpData} />)
    expect(document.querySelector('a')?.getAttribute('href')).toBe('vscode://file/home/me/projet/controllers/x.rb:4')
  })

  it('links the frames of the exception tab', () => {
    const exceptionData = {
      exception_class: 'Boom',
      message: 'bad',
      backtrace: [{ location: "/app/models/user.rb:12:in `save'", app_frame: true }],
    } as never
    render(<ExceptionTab exceptionData={exceptionData} />)
    const hrefs = [...document.querySelectorAll('a')].map((a) => a.getAttribute('href'))
    expect(hrefs).toEqual([
      'vscode://file/home/me/projet/models/user.rb:12',
      'vscode://file/home/me/projet/models/user.rb:12',
    ])
  })
})
