// Takes every screenshot of docs/screenshots/ from the demo application started by run.sh.
// Usage: node shoot.mjs <outdir>   (next to node_modules/playwright)
// Same frame for all: 1280x800 viewport, device scale factor 1, light theme.
import { chromium } from 'playwright'

const out = process.argv[2] || '.'
const MASTER = 'http://api.myapp.test:3000'
const browser = await chromium.launch({
  args: ['--host-resolver-rules=MAP api.myapp.test 127.0.0.1, MAP billing.myapp.test 127.0.0.1'],
})
const ctx = await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1, colorScheme: 'light' })
await ctx.addInitScript(() => {
  try { localStorage.setItem('profiler-theme', 'light') } catch (_) {}
})
const page = await ctx.newPage()
const settle = (ms = 900) => page.waitForTimeout(ms)
const shot = async (name) => { await settle(); await page.screenshot({ path: `${out}/${name}.png` }); console.log('shot', name) }
// Through the page, so that the browser's host mapping applies.
const api = (path) => page.evaluate(async (url) => (await fetch(url)).json(), `/_profiler/api/${path}`)

// The HTML page first: its toolbar, and the AJAX calls it makes once loaded.
const resp = await page.goto(`${MASTER}/orders`, { waitUntil: 'networkidle' })
const ordersToken = resp.headers()['x-profiler-token']
await page.waitForTimeout(2500) // AJAX sub-requests, then the toolbar refresh
await page.locator('#profiler-toolbar').getByText('DB', { exact: false }).first().hover().catch(() => {})
await shot('toolbar')

const list = (await api('profiles?limit=100')).profiles
const token = (path, method = 'GET') => list.find(p => p.path === path && p.method === method)?.token
const show = async (tok, tab, name, after) => {
  await page.goto(`${MASTER}/_profiler/profiles/${tok}?tab=${tab}`, { waitUntil: 'networkidle' })
  if (after) await after()
  await shot(name)
}

await page.goto(`${MASTER}/_profiler`, { waitUntil: 'networkidle' })
await shot('profile-list')

const checkout = token('/checkout')
await show(checkout, 'request', 'tab-request')
await show(checkout, 'dump', 'tab-dump')
await show(token('/api/n_plus_one'), 'database', 'tab-database')
await show(ordersToken, 'ajax', 'tab-ajax')
await show(checkout, 'http', 'tab-http', () => page.locator('.profiler-query-card, .profiler-http-card').first().click().catch(() => {}))
await show(checkout, 'timeline', 'tab-flamegraph')
await show(ordersToken, 'views', 'tab-views')
await show(token('/api/cache_intensive'), 'cache', 'tab-cache')
await show(checkout, 'logs', 'tab-logs')
await show(checkout, 'mailer', 'tab-mailer', () => page.locator('.profiler-query-card').first().click())
await show(checkout, 'jobs', 'tab-jobs')
await show(ordersToken, 'i18n', 'tab-i18n')
await show(ordersToken, 'routes', 'tab-routes')
await show(checkout, 'env', 'tab-env', async () => { await page.getByPlaceholder(/Filter by key/).fill('APP_'); await page.getByText('Reveal all').click() })
await show(token('/api/raise_named_error'), 'exception', 'tab-exception')

await page.goto(`${MASTER}/_profiler?section=jobs`, { waitUntil: 'networkidle' })
await shot('profile-list-jobs')

// Test runner: run the two demo spec files, which also records one test profile per example.
await page.goto(`${MASTER}/_profiler?section=runner`, { waitUntil: 'networkidle' })
await page.getByText('orders_spec.rb', { exact: true }).click()
await page.getByText('customers_spec.rb', { exact: true }).click()
await page.getByText(/Run Selected/).click()
await page.getByRole('button', { name: /Stop/ }).waitFor({ timeout: 10_000 })
await page.getByRole('button', { name: /Stop/ }).waitFor({ state: 'detached', timeout: 180_000 })
await shot('test-runner')

await page.goto(`${MASTER}/_profiler?section=tests`, { waitUntil: 'networkidle' })
await shot('profile-list-tests')
const tests = (await api('tests?limit=50')).profiles
const nPlusOne = tests.find(t => t.collectors_data?.test?.test_name?.includes('lists every item')) || tests[0]
await page.goto(`${MASTER}/_profiler/profiles/${nPlusOne.token}?tab=test`, { waitUntil: 'networkidle' })
await shot('test-profile')
await page.goto(`${MASTER}/_profiler/profiles/${nPlusOne.token}?tab=database`, { waitUntil: 'networkidle' })
await shot('test-profile-database')

// Cluster: the same list, read from the slave through the master.
await page.goto(`${MASTER}/_profiler`, { waitUntil: 'networkidle' })
await page.locator('.profiler-selector select').selectOption('myapp-billing')
await page.waitForLoadState('networkidle')
await shot('cluster-selector')

await browser.close()
