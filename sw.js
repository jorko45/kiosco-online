// K24 Service Worker — navegación network-first (precios siempre frescos),
// imágenes stale-while-revalidate, offline sirve el último catálogo visto.
const SHELL = 'k24-shell-v1';
const IMGS = 'k24-imgs-v1';

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.add('/')).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== SHELL && k !== IMGS).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Navegación: red primero, cache de respaldo (offline)
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(SHELL).then((c) => c.put('/', copy));
        return res;
      }).catch(() => caches.match('/'))
    );
    return;
  }

  // Imágenes (propias o de los CDN de productos): cache con revalidación
  if (req.destination === 'image' || /statics\.dinoonline|carrefourar|\/img\//.test(url.href)) {
    e.respondWith(
      caches.open(IMGS).then(async (c) => {
        const hit = await c.match(req);
        const net = fetch(req).then((res) => {
          if (res && res.status === 200) c.put(req, res.clone());
          return res;
        }).catch(() => hit);
        return hit || net;
      })
    );
  }
});
