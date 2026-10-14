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

// Toolbar panels, one image each: the same viewport, cut to its bottom 420 px (the toolbar
// and the open panel). The EVT item has had no data since 0.9.1 and never shows.
const PANEL_TOP = 380
const panel = async (item, name) => {
  await page.mouse.move(640, 100)
  await page.waitForTimeout(400)
  await item.hover()
  const open = page.locator('.profiler-toolbar-panel.is-visible')
  await open.waitFor()
  await settle(600)
  const box = await open.boundingBox()
  if (box.y < PANEL_TOP) throw new Error(`${name}: the panel is taller than the frame`)
  await page.screenshot({ path: `${out}/${name}.png`, clip: { x: 0, y: PANEL_TOP, width: 1280, height: 800 - PANEL_TOP } })
  console.log('shot', name)
}
const items = page.locator('.profiler-toolbar-item.profiler-toolbar-hoverable')
const item = (label) => items.filter({ has: page.locator(`span:text-is("${label}")`) }).first()
await panel(items.nth(0), 'toolbar-panel-request')
await panel(items.nth(1), 'toolbar-panel-performance')
for (const [label, name] of [['DB', 'database'], ['XHR', 'ajax'], ['VIEW', 'views'], ['CACHE', 'cache'], ['DUMP', 'dump'],
  ['LOG', 'logs'], ['ROUTE', 'routes'], ['I18N', 'i18n'], ['ENV', 'env']]) {
  await panel(item(label), `toolbar-panel-${name}`)
}
// The same order as /checkout, as an HTML page: outbound HTTP, jobs and mails.
await page.goto(`${MASTER}/orders/confirmation`, { waitUntil: 'networkidle' })
await page.waitForTimeout(2500)
for (const [label, name] of [['HTTP', 'http'], ['JOB', 'jobs'], ['MAIL', 'mailer']]) {
  await panel(item(label), `toolbar-panel-${name}`)
}
// A page whose job runs after its response: the JOB item, running, then completed in the same
// page, without a reload (the toolbar is told when the job is saved).
await page.goto(`${MASTER}/orders/export`, { waitUntil: 'domcontentloaded' })
await item('JOB').waitFor({ timeout: 10_000 })
await panel(item('JOB'), 'toolbar-panel-jobs-running')
const exportDone = Date.now() + 20_000
for (;;) {
  await page.mouse.move(640, 100)
  await page.waitForTimeout(1000)
  await item('JOB').hover()
  const open = page.locator('.profiler-toolbar-panel.is-visible')
  if (/Completed\s*1/.test(await open.innerText())) break
  if (Date.now() > exportDone) throw new Error('toolbar-panel-jobs-completed: the job never showed completed')
}
await panel(item('JOB'), 'toolbar-panel-jobs-completed')
// A page that raises: the development error page, without the web console drawn over it.
await page.goto(`${MASTER}/orders/broken`, { waitUntil: 'networkidle' })
await page.addStyleTag({ content: '#console { display: none !important; }' })
await page.waitForTimeout(1500)
await panel(item('💥'), 'toolbar-panel-exception')

// Turbo: a <turbo-frame> loaded with the page and a form answered with a Turbo Stream are
// sub-requests of the page, shown with their kind. A Drive visit is the next page: not linked,
// and the previous toolbar stops its update checks.
const turboResp = await page.goto(`${MASTER}/orders/turbo`, { waitUntil: 'networkidle' })
const turboToken = turboResp.headers()['x-profiler-token']
await page.locator('#customer_card', { hasText: 'recent order' }).waitFor()
await page.click('#refund_form button')
await page.locator('#refund_status', { hasText: 'Refund' }).waitFor()
await page.waitForTimeout(2500) // the links, then the toolbar refresh
const turboKinds = async () => (await api(`toolbar/${turboToken}`)).profile.collectors_data.ajax.requests.map(r => r.turbo).join()
if (await turboKinds() !== 'frame,stream') throw new Error(`Turbo sub-requests: ${await turboKinds()}`)
await panel(item('XHR'), 'toolbar-panel-ajax-turbo')
const oldPolls = []
page.on('request', r => { if (r.url().includes(`/_profiler/api/events/${turboToken}`)) oldPolls.push(r.url()) })
await page.mouse.move(640, 100)
await page.click('#all_orders')
await page.waitForURL(`${MASTER}/orders`)
await page.waitForTimeout(9000) // longer than the update checks' interval
if (await turboKinds() !== 'frame,stream') throw new Error(`Drive visit linked: ${await turboKinds()}`)
if (oldPolls.length) throw new Error(`the previous toolbar still polls: ${oldPolls.length} requests`)

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
await show(turboToken, 'ajax', 'tab-ajax-turbo')
await show(checkout, 'http', 'tab-http', () => page.locator('.profiler-query-card, .profiler-http-card').first().click().catch(() => {}))
await show(checkout, 'timeline', 'tab-flamegraph')
await show(checkout, 'timeline', 'tab-function-profiling', () =>
  page.locator('.profiler-fn-profiling').evaluate(el => window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 16)))
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
const jobs = (await api('jobs?limit=50')).profiles
await show(jobs.find(p => p.collectors_data?.job?.job_class === 'ReportGenerationJob').token, 'job', 'job-profile')

// Console expressions, recorded by run.sh through script/console_profiles.rb.
await page.goto(`${MASTER}/_profiler?section=console`, { waitUntil: 'networkidle' })
await shot('profile-list-console')
const consoles = (await api('console?limit=50')).profiles
await show(consoles.find(p => p.path.startsWith('Post.includes')).token, 'console', 'console-profile')

await page.goto(`${MASTER}/_profiler?section=outbound`, { waitUntil: 'networkidle' })
await page.locator('.profiler-ajax-card').nth(1).locator('.profiler-ajax-card__row').first().click()
await shot('profile-list-outbound')

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
await page.locator('.profiler-selector select').selectOption('__local__')
await page.waitForLoadState('networkidle')

// Last, because it changes the server's ENV: one override, made the way a user does.
await page.goto(`${MASTER}/_profiler?section=env`, { waitUntil: 'networkidle' })
await page.getByPlaceholder(/Filter by key/).fill('FEATURE_')
await page.locator('tr', { hasText: 'FEATURE_BETA_UI' }).locator('button[title^="Click to set"]').click()
await page.getByText('Reveal all').click()
await page.waitForTimeout(3500) // the confirmation message goes away after 3 s
await page.locator('h2', { hasText: 'Environment Variables' }).evaluate(el => window.scrollTo(0, el.getBoundingClientRect().top + window.scrollY - 16))
await shot('profile-list-env')

await browser.close()
