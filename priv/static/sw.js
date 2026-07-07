const CACHE = "rules-buddy-v4"

self.addEventListener("install", (event) => {
  self.skipWaiting()
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(["/"]))
  )
})

self.addEventListener("fetch", (event) => {
  if (event.request.mode === "navigate") {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          if (response && response.status === 200) {
            let clone = response.clone()
            caches.open(CACHE).then((cache) => cache.put(event.request, clone))
          }
          return response
        })
        .catch(() => caches.match(event.request))
    )
    return
  }

  // Network-first for assets: always prefer fresh from the server when online
  // (so CSS/JS edits show up immediately), fall back to cache only when offline.
  // cache: "no-cache" forces an etag revalidation instead of trusting the HTTP
  // cache — without it, fetch() inside a service worker happily replays a stale
  // heuristically-cached CSS/JS response (Safari's hard refresh doesn't bypass
  // a controlling worker, so edits never showed up).
  event.respondWith(
    fetch(event.request, { cache: "no-cache" })
      .then((response) => {
        if (response && response.status === 200) {
          let clone = response.clone()
          caches.open(CACHE).then((cache) => cache.put(event.request, clone))
        }
        return response
      })
      .catch(() => caches.match(event.request))
  )
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    Promise.all([
      caches.keys().then((keys) =>
        Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
      ),
      self.clients.claim()
    ])
  )
})
