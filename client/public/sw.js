/*
 * Omlete's service worker: keeps the app shell on the phone so a list opened
 * at home still opens in a shop with no signal.
 *
 * - Pages: network first, falling back to the last copy of that page.
 * - Built assets (/assets/*, hashed): cache first; they never change.
 * - Everything else, including the API: untouched. List data has its own
 *   offline copy and change queue in localStorage (src/lib/offline.ts).
 */
const PAGES = 'omlete-pages-v1'
const ASSETS = 'omlete-assets-v1'

self.addEventListener('install', () => self.skipWaiting())

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys.filter((k) => ![PAGES, ASSETS].includes(k)).map((k) => caches.delete(k)),
        ),
      )
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const req = event.request
  if (req.method !== 'GET') return
  const url = new URL(req.url)
  if (url.origin !== self.location.origin) return

  if (req.mode === 'navigate') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          if (res.ok) {
            const copy = res.clone()
            caches.open(PAGES).then((c) => c.put(req, copy))
          }
          return res
        })
        .catch(() =>
          caches
            .match(req, { ignoreSearch: true })
            .then((hit) => hit || caches.match('/', { cacheName: PAGES }))
            .then((hit) => hit || Response.error()),
        ),
    )
    return
  }

  if (url.pathname.startsWith('/assets/') || /\.(js|css|woff2?|png|svg|ico)$/.test(url.pathname)) {
    event.respondWith(
      caches.match(req).then(
        (hit) =>
          hit ||
          fetch(req).then((res) => {
            if (res.ok) {
              const copy = res.clone()
              caches.open(ASSETS).then((c) => c.put(req, copy))
            }
            return res
          }),
      ),
    )
  }
})
