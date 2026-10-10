// Drive the Omlete UI in headless Chromium and save evidence.
// Invoked via `omlete-verify browse`; see ../SKILL.md for the step flags.
//
// Steps run in argv order after the path:
//   --expect TEXT         wait until TEXT is visible (exact substring)
//   --absent TEXT         assert TEXT is not visible
//   --click-link TEXT     click the link whose accessible name is TEXT
//   --click-button TEXT   click the button whose accessible name is TEXT
//   --fill LABEL=VALUE    fill the textbox with that accessible name/placeholder
//   --click-sel SELECTOR  click the first match of a Playwright selector (for
//                         controls with no accessible name, e.g. star ratings)
//   --fill-sel SEL=>VALUE fill the first match of a Playwright selector
//   --press KEY           press a key in the focused element (e.g. Enter)
//   --expect-url REGEX    wait until the URL path matches REGEX
//   --timeout MS          per-step timeout for later steps (default 20000)
//   --accept-dialogs      auto-accept confirm() dialogs from here on
//   --label NAME          evidence folder name (default: derived from path)
//
// Fails (exit 1) when a step fails, when any /api request goes anywhere but
// OMLETE_API, or when an /api request comes back non-2xx.
import { createRequire } from 'node:module'
import fs from 'node:fs'
import path from 'node:path'

const require = createRequire(path.join(process.env.OMLETE_TOOLS_DIR, 'package.json'))
const { chromium } = require('playwright')

const WEB = process.env.OMLETE_WEB
const API = process.env.OMLETE_API
let TIMEOUT = 20_000

const [target, ...rest] = process.argv.slice(2)
const steps = []
let label = target.replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '') || 'root'
for (let i = 0; i < rest.length; i++) {
  const flag = rest[i]
  if (flag === '--accept-dialogs') steps.push({ flag })
  else if (flag === '--label') label = rest[++i]
  else steps.push({ flag, arg: rest[++i] })
}

const stamp = new Date().toISOString().replace(/[:.]/g, '-')
const outDir = path.join(process.env.OMLETE_EVIDENCE_DIR, `${stamp}-${label}`)
fs.mkdirSync(outDir, { recursive: true })

const log = []
const apiCalls = []
const problems = []
const note = (s) => { log.push(s); console.log(s) }

const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
page.on('console', (m) => { if (m.type() === 'error') log.push(`console.error: ${m.text()}`) })
page.on('pageerror', (e) => log.push(`pageerror: ${e.message}`))
page.on('response', (r) => {
  const u = new URL(r.url())
  if (!u.pathname.startsWith('/api/')) return
  const entry = `${r.request().method()} ${r.url()} -> ${r.status()}`
  apiCalls.push(entry)
  if (u.origin !== API) problems.push(`API call went to ${u.origin}, not ${API}: ${entry}`)
  else if (r.status() >= 400) problems.push(`API error: ${entry}`)
})
page.on('requestfailed', (r) => {
  if (!new URL(r.url()).pathname.startsWith('/api/')) return
  const err = r.failure()?.errorText
  // A navigation cancels in-flight queries (e.g. the detail refetch after
  // Delete navigates away). That's the browser, not the API.
  if (err === 'net::ERR_ABORTED') apiCalls.push(`${r.method()} ${r.url()} -> aborted by navigation`)
  else problems.push(`API request failed (CORS, or a 500 - see .verify-run/api.log): ${r.url()} ${err}`)
})

let failed = false
let shot = 0
const snap = async (tag) => {
  const base = path.join(outDir, `${String(++shot).padStart(2, '0')}-${tag}`)
  await page.screenshot({ path: `${base}.png`, fullPage: true })
  fs.writeFileSync(`${base}.aria.txt`, await page.locator('body').ariaSnapshot())
}

try {
  note(`goto ${WEB}${target}`)
  await page.goto(`${WEB}${target}`, { waitUntil: 'domcontentloaded' })
  // The HTML is server-rendered, so buttons exist before React hydrates and a
  // click that early is silently dropped. Vite dev serves hundreds of modules;
  // network idle is the first point the page is reliably interactive.
  await page.waitForLoadState('networkidle', { timeout: 60_000 })
  await snap('loaded')
  for (const { flag, arg } of steps) {
    note(`${flag}${arg !== undefined ? ` ${JSON.stringify(arg)}` : ''}`)
    switch (flag) {
      case '--expect':
        await page.getByText(arg).first().waitFor({ state: 'visible', timeout: TIMEOUT })
        break
      case '--absent':
        await page.waitForTimeout(500)
        if (await page.getByText(arg).first().isVisible()) throw new Error(`"${arg}" is visible`)
        break
      case '--click-link':
        await page.getByRole('link', { name: arg }).first().click({ timeout: TIMEOUT })
        break
      case '--click-button':
        await page.getByRole('button', { name: arg }).first().click({ timeout: TIMEOUT })
        break
      case '--fill': {
        const eq = arg.indexOf('=')
        const name = arg.slice(0, eq), value = arg.slice(eq + 1)
        await page.getByRole('textbox', { name }).or(page.getByPlaceholder(name)).first().fill(value, { timeout: TIMEOUT })
        break
      }
      case '--click-sel':
        await page.locator(arg).first().click({ timeout: TIMEOUT })
        break
      case '--fill-sel': {
        const at = arg.indexOf('=>')
        await page.locator(arg.slice(0, at)).first().fill(arg.slice(at + 2), { timeout: TIMEOUT })
        break
      }
      case '--timeout':
        TIMEOUT = Number(arg)
        break
      case '--press':
        await page.keyboard.press(arg)
        break
      case '--expect-url':
        await page.waitForURL((u) => new RegExp(arg).test(u.pathname), { timeout: TIMEOUT })
        break
      case '--accept-dialogs':
        page.on('dialog', (d) => { log.push(`dialog accepted: ${d.message()}`); d.accept() })
        break
      default:
        throw new Error(`unknown step ${flag}`)
    }
    await snap(flag.replace(/^--/, ''))
  }
  await page.waitForLoadState('networkidle', { timeout: 5000 }).catch(() => {})
} catch (e) {
  failed = true
  note(`STEP FAILED: ${e.message.split('\n')[0]}`)
  await snap('failure').catch(() => {})
}

if (problems.length) failed = true
fs.writeFileSync(path.join(outDir, 'final.aria.txt'), await page.locator('body').ariaSnapshot().catch(() => ''))
await page.screenshot({ path: path.join(outDir, 'final.png'), fullPage: true }).catch(() => {})
fs.writeFileSync(path.join(outDir, 'run.log'), [
  `url: ${page.url()}`, `result: ${failed ? 'FAIL' : 'PASS'}`, '', '## steps', ...log,
  '', '## /api calls', ...apiCalls, '', '## problems', ...problems,
].join('\n') + '\n')
await browser.close()

for (const p of problems) console.log(`PROBLEM: ${p}`)
console.log(`${failed ? 'FAIL' : 'PASS'}  evidence: ${path.relative(process.cwd(), outDir) || outDir}`)
process.exit(failed ? 1 : 0)
