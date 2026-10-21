import { getActiveSlavePrefix } from './cluster-context'

const MASTER_ONLY_PATHS = ['/_profiler/api/cluster/', '/_profiler/api/toolbar/', '/_profiler/api/events/']

// Endpoints that should never receive the slave prefix: cluster management, toolbar UI, and event polling.
function shouldSkipSlavePrefix(url: string): boolean {
  return MASTER_ONLY_PATHS.some(path => url.startsWith(path))
}

// Custom HTTP fetcher for orval-generated code, uses native fetch, no axios dependency.
export async function apiFetch<T>(config: {
  url: string
  method: string
  params?: Record<string, unknown>
  data?: unknown
  headers?: Record<string, string>
  signal?: AbortSignal
}): Promise<T> {
  // Endpoints like cluster, toolbar, and events belong to the master. Sent through a slave proxy,
  // cluster endpoints would reach a node that does not route them and the selector would disappear.
  // Toolbar and events endpoints do not exist on slaves, causing 404s and "Profiler data could not be loaded" errors.
  const prefix = shouldSkipSlavePrefix(config.url) ? '' : getActiveSlavePrefix()
  const resolvedUrl = prefix
    ? config.url.replace('/_profiler/api', `/_profiler/api${prefix}`)
    : config.url

  const { method, params, data, headers = {}, signal } = config
  const url = resolvedUrl

  const qs = params
    ? '?' + new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)])).toString()
    : ''

  // Every request carries this header: the profiler refuses a mutation without it, and a page
  // on another origin cannot add it without a CORS preflight.
  const baseHeaders: Record<string, string> = { 'X-Profiler-Request': '1', ...headers }

  const res = await fetch(url + qs, {
    method,
    signal,
    headers: data !== undefined ? { 'Content-Type': 'application/json', ...baseHeaders } : baseHeaders,
    body: data !== undefined ? JSON.stringify(data) : undefined,
  })

  if (res.status === 204) return {} as T

  const json = await res.json()

  if (!res.ok) {
    throw Object.assign(new Error(json?.error ?? `HTTP ${res.status}`), { status: res.status, data: json })
  }

  return json
}
