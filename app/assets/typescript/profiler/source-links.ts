// Builds the editor URLs behind the file:line links. Pure functions: the settings come from
// GET /_profiler/api/config (see useEditorConfig).

// The only schemes a link may use. The scheme reaches the page from the server, so it is
// checked here as well: anything else (javascript:, data:, an unknown editor) yields no link.
export const EDITOR_SCHEMES = ['vscode', 'idea', 'cursor'] as const
export type EditorScheme = (typeof EDITOR_SCHEMES)[number]

export interface EditorSettings {
  scheme: string | null | undefined
  pathMap?: Record<string, string> | null
}

export function isEditorScheme(value: unknown): value is EditorScheme {
  return typeof value === 'string' && (EDITOR_SCHEMES as readonly string[]).includes(value)
}

const DRIVE = /^[A-Za-z]:\//

function normalize(path: string): string {
  return path.replace(/\\/g, '/')
}

// Replaces the longest container prefix that matches on a path segment boundary.
export function mapPath(path: string, pathMap?: Record<string, string> | null): string {
  if (!pathMap) return path
  let best: string | null = null
  for (const from of Object.keys(pathMap)) {
    const prefix = normalize(from).replace(/\/+$/, '')
    if (path === prefix || path.startsWith(prefix + '/')) {
      if (best === null || prefix.length > normalize(best).replace(/\/+$/, '').length) best = from
    }
  }
  if (best === null) return path
  const prefix = normalize(best).replace(/\/+$/, '')
  const target = normalize(String(pathMap[best])).replace(/\/+$/, '')
  return target + path.slice(prefix.length)
}

function isAbsolute(path: string): boolean {
  return path.startsWith('/') || DRIVE.test(path)
}

// Each segment is escaped, the separators are kept: an editor expects a path, not one token.
function encodePath(path: string): string {
  const withSlash = path.startsWith('/') ? path : '/' + path
  return withSlash
    .split('/')
    .map((segment, i) => (i === 1 && /^[A-Za-z]:$/.test(segment) ? segment : encodeURIComponent(segment)))
    .join('/')
}

// null when no safe link can be built: unknown scheme, relative path, invalid line.
export function buildEditorUrl(file: string, line: number, settings: EditorSettings): string | null {
  const { scheme, pathMap } = settings
  if (!isEditorScheme(scheme)) return null
  if (!Number.isInteger(line) || line < 1) return null
  if (typeof file !== 'string' || file === '' || file.includes('\0')) return null

  const mapped = mapPath(normalize(file), pathMap)
  if (!isAbsolute(mapped)) return null

  if (scheme === 'idea') {
    return `idea://open?file=${encodeURIComponent(mapped)}&line=${line}`
  }
  return `${scheme}://file${encodePath(mapped)}:${line}`
}

// "/app/models/user.rb:12:in `save'" => { file, line }; null when it carries no line.
export function parseFrame(frame: string): { file: string; line: number } | null {
  const match = /^(.+?):(\d+)(?::in\b.*)?$/.exec(frame)
  if (!match) return null
  return { file: match[1], line: Number(match[2]) }
}
