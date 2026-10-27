// The AJAX interceptor under Node, in a fake window: fetch answers like the profiled
// application, Turbo is played by its turbo:before-fetch-request event, and the test reads which
// tokens the interceptor links, and to which page. Run by spec/ajax_interceptor_js_spec.rb.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

const SOURCE = readFileSync(new URL('../../app/assets/javascript/profiler-ajax-interceptor.js', import.meta.url), 'utf8')

function load({ parentToken = 'page-1', linkResponses } = {}) {
  const links = []
  const responses = new Map()
  let linkAttemptCount = 0
  const window = new EventTarget()
  const document = new EventTarget()
  // The toolbar element exists on a profiled page only.
  let profiledPage = true
  document.getElementById = id => (id === 'profiler-toolbar' && profiledPage ? {} : null)
  window.__PROFILER_PARENT_TOKEN__ = parentToken
  window.location = { origin: 'http://localhost' }
  window.fetch = async (input, init = {}) => {
    const url = new URL(input instanceof Request ? input.url : String(input), 'http://localhost')
    if (url.pathname === '/_profiler/api/ajax/link') {
      links.push(JSON.parse(init.body))
      // Support configurable response statuses for testing retry logic
      if (linkResponses && linkResponses.length > 0) {
        const status = linkResponses[linkAttemptCount] || 200
        linkAttemptCount++
        return new Response('{}', { status })
      }
      return new Response('{}', { status: 200 })
    }
    const { token, contentType = 'text/html; charset=utf-8' } = responses.get(url.pathname)
    return new Response('', { headers: { 'X-Profiler-Token': token, 'Content-Type': contentType } })
  }
  class XMLHttpRequest extends EventTarget {
    open(method, url) { this.url = url }
    send() {
      const { token } = responses.get(this.url)
      this.getResponseHeader = name => (name === 'X-Profiler-Token' ? token : null)
      queueMicrotask(() => this.dispatchEvent(new Event('load')))
    }
  }
  const context = {
    window, document, XMLHttpRequest, Request, URL, CustomEvent, setTimeout,
    console: { debug() {}, warn() {} },
  }
  vm.runInNewContext(SOURCE, context)

  // What Turbo does for each of its requests: the event, then fetch with the same options.
  async function turboFetch(path, headers = {}) {
    const fetchOptions = { method: 'GET', headers: { Accept: 'text/html, application/xhtml+xml', ...headers }, signal: new AbortController().signal }
    document.dispatchEvent(new CustomEvent('turbo:before-fetch-request', { detail: { fetchOptions, url: new URL(path, 'http://localhost') } }))
    return window.fetch(path, fetchOptions)
  }
  const settled = () => new Promise(resolve => setTimeout(resolve, 0))
  // What Turbo does once it has rendered a page: the body is replaced, then turbo:load.
  function turboLoad({ profiled }) {
    profiledPage = profiled
    document.dispatchEvent(new CustomEvent('turbo:load'))
  }
  return { window, XMLHttpRequest, links, responses, turboFetch, turboLoad, settled }
}

test('links a Turbo Frame request to the page', async () => {
  const t = load()
  t.responses.set('/orders/turbo/customer', { token: 'frame-1' })
  await t.turboFetch('/orders/turbo/customer', { 'Turbo-Frame': 'customer_card' })
  await t.settled()
  assert.deepEqual(t.links, [{ parent_token: 'page-1', child_token: 'frame-1' }])
})

test('links a Turbo request answered with Turbo Stream actions', async () => {
  const t = load()
  t.responses.set('/orders/turbo/refund', { token: 'stream-1', contentType: 'text/vnd.turbo-stream.html; charset=utf-8' })
  await t.turboFetch('/orders/turbo/refund', { Accept: 'text/vnd.turbo-stream.html, text/html, application/xhtml+xml' })
  await t.settled()
  assert.deepEqual(t.links, [{ parent_token: 'page-1', child_token: 'stream-1' }])
})

test('does not link a Turbo Drive visit nor a prefetch: they are the next page', async () => {
  const t = load()
  t.responses.set('/orders', { token: 'next-page' })
  await t.turboFetch('/orders', { 'X-Sec-Purpose': 'prefetch' })
  await t.turboFetch('/orders')
  await t.settled()
  assert.deepEqual(t.links, [])
})

test('links the sub-requests made after a Drive visit to the new page', async () => {
  const t = load()
  t.responses.set('/orders', { token: 'page-2' })
  t.responses.set('/api/users', { token: 'json-1' })
  t.responses.set('/api/legacy', { token: 'xhr-1' })
  await t.turboFetch('/orders')
  // The new body's inline script, run by Turbo when it renders the page.
  t.window.__PROFILER_PARENT_TOKEN__ = 'page-2'
  await t.window.fetch('/api/users')
  const xhr = new t.XMLHttpRequest()
  xhr.open('GET', '/api/legacy')
  xhr.send()
  await t.settled()
  assert.deepEqual(t.links, [
    { parent_token: 'page-2', child_token: 'json-1' },
    { parent_token: 'page-2', child_token: 'xhr-1' },
  ])
})

test('links a plain fetch, whether given a string, a URL or a Request', async () => {
  const t = load()
  t.responses.set('/api/users', { token: 'json-1' })
  await t.window.fetch('/api/users')
  await t.window.fetch(new URL('http://localhost/api/users'))
  await t.window.fetch(new Request('http://localhost/api/users'))
  await t.settled()
  assert.deepEqual(t.links.map(l => l.child_token), ['json-1', 'json-1', 'json-1'])
})

test('links nothing after a Drive visit to a page the profiler left alone', async () => {
  const t = load()
  t.responses.set('/api/users', { token: 'json-1' })
  t.turboLoad({ profiled: false })
  await t.window.fetch('/api/users')
  await t.settled()
  assert.deepEqual(t.links, [])
})

test('links to the token of the page a Drive visit renders, not the first one', async () => {
  const t = load()
  t.responses.set('/api/users', { token: 'json-1' })
  // The new body's inline script sets the token, then Turbo fires turbo:load.
  t.window.__PROFILER_PARENT_TOKEN__ = 'page-2'
  t.turboLoad({ profiled: true })
  await t.window.fetch('/api/users')
  await t.settled()
  assert.deepEqual(t.links, [{ parent_token: 'page-2', child_token: 'json-1' }])
})

test('retries on 404 and succeeds on retry', async () => {
  const t = load({ linkResponses: [404, 200] })
  t.responses.set('/api/users', { token: 'json-1' })
  await t.window.fetch('/api/users')
  // First attempt fails with 404, retry scheduled. Wait for the retry to complete.
  await new Promise(resolve => setTimeout(resolve, 150)) // 100ms backoff + margin
  // Should have 2 link attempts: first returns 404, second returns 200. Both are recorded in links.
  assert.equal(t.links.length, 2)
  assert.deepEqual(t.links[0], { parent_token: 'page-1', child_token: 'json-1' })
  assert.deepEqual(t.links[1], { parent_token: 'page-1', child_token: 'json-1' })
})

test('exhausts retries on repeated 404s', async () => {
  const t = load({ linkResponses: [404, 404, 404, 404] }) // More than 3 attempts to ensure we stop
  t.responses.set('/api/users', { token: 'json-1' })
  await t.window.fetch('/api/users')
  // All 3 retries will be attempted. Wait for all backoff periods: 100ms + 200ms + 400ms + margin.
  await new Promise(resolve => setTimeout(resolve, 750))
  // Should have made exactly 3 attempts (initial + 2 retries = 3 total)
  assert.equal(t.links.length, 3)
  assert.deepEqual(t.links[0], { parent_token: 'page-1', child_token: 'json-1' })
  assert.deepEqual(t.links[1], { parent_token: 'page-1', child_token: 'json-1' })
  assert.deepEqual(t.links[2], { parent_token: 'page-1', child_token: 'json-1' })
})

test('succeeds immediately on 200 (regression test)', async () => {
  const t = load({ linkResponses: [200] })
  t.responses.set('/api/users', { token: 'json-1' })
  await t.window.fetch('/api/users')
  await t.settled()
  assert.deepEqual(t.links, [{ parent_token: 'page-1', child_token: 'json-1' }])
})

test('handles null URL in XMLHttpRequest.open() without throwing', async () => {
  const t = load()
  t.responses.set('null', { token: 'xhr-1' })
  const xhr = new t.XMLHttpRequest()
  // Should not throw when url is null; String(null) converts to 'null'
  assert.doesNotThrow(() => {
    xhr.open('GET', null)
  })
})

test('does not duplicate load event listeners on reused XHR', async () => {
  const t = load()
  t.responses.set('/api/users', { token: 'xhr-1' })
  const xhr = new t.XMLHttpRequest()
  // Reuse the same XHR object for multiple sends
  xhr.open('GET', '/api/users')
  xhr.send()
  await t.settled()

  // Reuse the same xhr for a second send with a different URL
  t.responses.set('/api/posts', { token: 'xhr-2' })
  xhr.open('GET', '/api/posts')
  xhr.send()
  await t.settled()

  // Should have 2 links, one per send (no duplication)
  assert.equal(t.links.length, 2, 'each send should link once, even on reused XHR')
})
