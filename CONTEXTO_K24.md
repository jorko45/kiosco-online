# Contexto para continuar proyecto K24
*(actualizado 11-jul-2026)*

## Qué es
K24 — Kiosco online 24hs con delivery rápido (~20-30 min) en Córdoba Capital. El cliente paga al recibir (efectivo), por MercadoPago o transferencia. Envío $5.000 (gratis primeras 10 compras de $50k+). Se puede comprar 24hs: fuera de horario el pedido queda registrado y sale al empezar el reparto (8:00).

## Infraestructura
- **Dominio propio: https://k24hs.com** (comprado en Vercel, $11.25/año, vence 10-jul-2027, auto-renew ON, conectado al proyecto). El viejo kiosco-online.vercel.app sigue funcionando.
- Repo GitHub: `https://github.com/jorko45/kiosco-online` (branch `main`)
- Archivo principal: `C:\Users\joe\Claude\Projects\k24\index.html` — single-file SPA (HTML/CSS/JS, ~660KB)
- **Git push: siempre `git push origin master:main`** vía archivos `.bat` (el usuario los corre; la IA no tiene credenciales)
- Vercel: deploy automático al pushear a `main`. ⚠️ A veces Vercel se pierde el webhook: un commit vacío + push lo destraba.
- ⭐ Cuenta Google del proyecto: **k24hsonline@gmail.com** — TODO lo de Google (planillas, Drive, Apps Script, backups) va acá. NO usar montagna@gmail.com (personal de Joe). El mail k24hsonline se creó para que la IA maneje las herramientas de Google del proyecto.
  - ⚠️ Estado actual (18-jul-2026): el Apps Script backend (exec .../AKfycbz48Hs8...) está corriendo bajo **montagna** por error histórico, así que las planillas que crea (K24 Cuentas, Pedidos K24, "precios editable google") cayeron en el Drive de montagna. Pendiente: consolidar todo en k24hsonline (transferir propiedad de las planillas y/o migrar el proyecto Apps Script a k24hsonline). montagna está casi sin espacio (90/100 GB).
- MercadoPago: token en env `MP_ACCESS_TOKEN` de Vercel; endpoint `api/crear-pago.js` (back_urls a k24hs.com, picture_url = logo K24, statement_descriptor "K24 KIOSCO"). Falta que Joe suba el logo en su cuenta MP (Configuración → Datos de tu negocio, archivo `img/k24-logo.png`).
- **PWA activa**: manifest.json + sw.js (navegación network-first, imágenes cache, offline muestra último catálogo) + íconos en img/icon-*.png + botón "Instalar la app" en el inicio.

## Scripts .bat (workflow del usuario)
- **`push_solo.bat`** — solo git push (borra index.lock viejo antes). Uso: deployar cambios ya commiteados.
- **`sync_mami.bat`** — corre `sync_mami.py` + commit + push. **Es la rutina de actualización de precios.**
- **`bajar_fotos_cigarrillos.bat`** — baja fotos hotlinkeadas de cdn.pedix.app a local (idempotente).
- ⚠️ Python en Windows: usar contexto SSL sin verificación (ya está en los scripts).

## sync_mami.py — "el Mami es la madre"
Scrapea SuperMami (dinoonline.com.ar) y actualiza index.html:
1. Regenera el bloque `catalogGolosinasMami` (marcadores `// MAMI-AUTOGEN-START/END`) con 9 categorías: alfajores, chocolates, golosinas, obleas, postre de maní + 4 de galletas (dulces/saladas/arroz/sin sal). ~730 productos.
2. Actualiza precios por id de producto en todas las categorías `supermami-bebidas-*`.
3. **Aplica márgenes automáticamente**: `precio_final = base × (1+margen) × 1.066 (comisión MP) redondeado a $50`. Margen 15% marcas primeras (lista PRIMERAS_MARCAS en el script), 25% el resto.
- URL de categorías Mami: `/super/categoria/{slug}/_/{N-code}?No=0&Nrpp=500`; búsqueda: `/super/categoria?_dyncharset=utf-8&Dy=1&Nty=1&Nrpp=50&Ntt={query}`.
- Imágenes Dino CDN: `https://statics.dinoonline.com.ar/imagenes/full_600x600_ma/{id}_f.jpg` (fallback runtime a `medium_150x150/{id}_m.jpg` vía `gonImgFallback()` — algunos productos de almacén solo tienen la mediana).

## Precios y márgenes (aplicado 10-jul-2026)
- TODO el catálogo (~2.700 productos) tiene margen: 15% primeras marcas / 25% resto + 6.6% MP, redondeo $50. Marcador en el código: `// MARGEN-APPLIED v1`. **NO volver a aplicar márgenes sobre los precios actuales** (los de heladera/cigarrillos/góndola están margineados una vez; los del Mami se recalculan solos en cada sync desde el precio base).
- Promos: sin margen (precio armado por Joe).
- Excel de referencia: `lista_precios_k24_v2.xlsx` (hoja "Grupos y Margen" con 381 subgrupos por marca).
- Cigarrillos: lista "Distribuidora del Centro" 1/07/26 ÷10 (precio unitario por atado) + margen completo. Cuando llegue lista nueva: pasar la foto y recalcular.

## Estructura del index.html
- `const catalog = {gaseosas, aguas, cervezas, energizantes, promos, botellas, pritty, jugosm, cigarrillos}` — brand cards `{id, name, color, textColor, logo, variants:[{vid, size, price, img}]}`. Modal: `openModal(brandId, shelfKey)`.
- Flat SuperMami: `catalogVinos, catalogLicores, catalogSaborizadas, catalogCervezas, catalogAguasExtra, catalogGaseosasExtra, catalogJugos, catalogEspumantes` — `{id:'<dino-id>', name, qty, price, img}`.
- Góndola/golosinas Carrefour-style: `catalogGondola, catalogGolosinas` — `{id:'prod<dino-id>', name, brand, cat, price, img}` (los ids "prod" también son ids del Mami).
- `catalogGolosinasMami` — bloque autogenerado por sync (NO editar a mano).
- `vinosMarcas`/`licoresMarcas` — agrupación de vinos/licores por bodega/marca (con logos), renderizado por `renderBotellasAll()`.
- **Secciones**: Landing (con portada del kiosco clickeable + caja de pagos + grid) · Heladera (6 estantes brand cards) · Botellas (🍷 Cava de vinos con estantes de madera / 🥃 Toneles de whisky / 🧉 Góndola de aperitivos y licores — sin categorías duplicadas, marcas fusionadas) · Promos · Góndola (tabs) · Golosinas (12 tabs) · Cigarrería (22 marcas, premium + económicos, +18).
- **Portada clickeable**: `img/kiosco-hero.jpg` con 8 hotspots (`.kh-zone` con % sobre la imagen) → golosinas, góndola, caja (×2), promos, heladeras, cigarrería, botellas.
- Buscador global (`getAllSearchableProducts`) busca en TODO incl. Mami y cigarrillos; botón + agrega al carrito; botón flotante `#fabCaja` en el landing abre el carrito.
- Logos: `img/logos/` (~270 archivos, nombres en minúscula-con-guiones; los de cigarrillos son `cig-<marca>.jpg`). Marcas sin archivo usan wordmark SVG (data URI o `_mkWordmark()` runtime).
- Fotos cigarrillos: `img/cigarrillos/` (25 de Pedix, locales).

## Repartidores
- Jorge — Zona Sur (lat < -31.41) — WhatsApp 3515479266
- Patricia — Zona Norte (lat > -31.41) — WhatsApp 3516986141

## ⚠️ Trampas conocidas del entorno
- El mount de Windows es **case-insensitive**: renombrar archivos solo por mayúsculas requiere 2 pasos, y `git add -A` no detecta case-renames (usar `git update-index --cacheinfo` sobre el árbol). Vercel SÍ es case-sensitive.
- Al escribir index.html desde scripts puede truncarse: escribir a /tmp y copiar, verificar tamaño (>600KB) y que exista `</script>`.
- `.git/index.lock` viejo puede trabar git (los .bat lo borran).
- Verificar sintaxis JS tras editar: extraer el `<script>` y `node --check`.

## Pendientes / roadmap
1. **Sistema de pedidos entrantes** (hoy salen por WhatsApp al repartidor según zona; hay `api/registrar-usuario.js` que guarda perfiles en Google Sheets — se podría replicar para pedidos).
2. Historial de pedidos / fidelización (hay créditos de envío gratis ya implementados).
3. Bug: botón MP queda en "Procesando..." si el usuario vuelve del checkout.
4. Notificaciones push (fase 2 de la PWA).
5. Subir logo K24 en la cuenta de MercadoPago (manual de Joe).
6. Algunos logos de vinos son fotos de botella en vez de logo puro (reemplazables en img/logos/).

## Últimos commits relevantes
- Portada kiosco clickeable + imagen (`042345a`, `8ef4b95`)
- 22 logos cigarrillos (`9bbcc60`)
- Galletas Mami + fix ~95 imágenes + fallback (`423a077`, `eb038b7`)
- Márgenes en todo el catálogo (`07fcc3b`)
- URLs MP a k24hs.com (`056793c`) · PWA (`82ec77c`) · Cigarrería (`9404f37`)
