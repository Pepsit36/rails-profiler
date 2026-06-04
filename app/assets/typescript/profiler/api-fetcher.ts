// Custom HTTP fetcher for orval-generated code — uses native fetch, no axios dependency.
export async function apiFetch<T>(config: {
  url: string
  method: string
  params?: Record<string, unknown>
  data?: unknown
  headers?: Record<string, string>
  signal?: AbortSignal
}): Promise<T> {
  const { url, method, params, data, headers = {}, signal } = config

  const qs = params
    ? '?' + new URLSearchParams(Object.entries(params).map(([k, v]) => [k, String(v)])).toString()
    : ''

  const res = await fetch(url + qs, {
    method,
    signal,
    headers: data !== undefined ? { 'Content-Type': 'application/json', ...headers } : headers,
    body: data !== undefined ? JSON.stringify(data) : undefined,
  })

  if (res.status === 204) return {} as T

  const json = await res.json()

  if (!res.ok) {
    throw Object.assign(new Error(json?.error ?? `HTTP ${res.status}`), { status: res.status, data: json })
  }

  return json
}
