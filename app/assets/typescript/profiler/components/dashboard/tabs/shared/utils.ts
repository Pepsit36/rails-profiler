export function methodBadge(method: string): string {
  const map: Record<string, string> = { GET: 'info', POST: 'success', PUT: 'warning', PATCH: 'warning', DELETE: 'error' }
  return map[method] || 'default'
}

export function statusBadge(status: number): string {
  if (status === 0) return 'error'
  if (status >= 200 && status < 300) return 'success'
  if (status >= 400) return 'error'
  return 'warning'
}

export function formatBytes(bytes: number): string {
  if (bytes < 0) return '—'
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  return `${(bytes / (1024 * 1024)).toFixed(2)} MB`
}
