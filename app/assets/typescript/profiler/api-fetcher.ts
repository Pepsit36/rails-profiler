import { getActiveSlavePrefix } from './cluster-context'

const MASTER_ONLY_PREFIX = '/_profiler/api/cluster/'

// Custom HTTP fetcher for orval-generated code, uses native fetch, no axios dependency.
export async function apiFetch<T>(config: {
  url: string
  method: string
  params?: Record<string, unknown>
  data?: unknown
  headers?: Record<string, string>
  signal?: AbortSignal
}): Promise<T> {
  // The cluster endpoints belong to the master, which the slave selector asks which slaves
  // exist: sent through the proxy of the slave being viewed, they would reach a node that does
  // not route them and the selector would disappear.
  const prefix = config.url.startsWith(MASTER_ONLY_PREFIX) ? '' : getActiveSlavePrefix()
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
