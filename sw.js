// K24 Service Worker — navegación network-first (precios siempre frescos),
// imágenes stale-while-revalidate, offline sirve el último catálogo visto.
const SHELL = 'k24-shell-v3';   // v3: cada pagina guarda su propia copia offline
const IMGS = 'k24-imgs-v2';

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

  // Navegación: red primero, cache de respaldo (offline).
  //
  // OJO: antes esto guardaba TODA navegación bajo la clave '/'. Con una sola
  // página no se notaba, pero al sumar /kiosco.html y /red.html significaba
  // que entrar al panel del kiosco pisaba la copia offline de la tienda: el
  // cliente abría k24hs.com sin señal y le aparecía la pantalla del kiosquero.
  // Ahora cada página guarda la suya.
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req).then((res) => {
        const copy = res.clone();
        caches.open(SHELL).then((c) => c.put(url.pathname, copy));
        return res;
      }).catch(() => caches.match(url.pathname).then((hit) => hit || caches.match('/')))
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
