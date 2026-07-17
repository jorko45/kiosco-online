# -*- coding: utf-8 -*-
"""
sync_mami.py — Sincroniza K24 con SuperMami (dinoonline.com.ar)

1. Scrapea las categorías configuradas del Mami.
2. Regenera el bloque catalogGolosinasMami de index.html (golosinas y chocolates completo).
3. Actualiza el precio de CUALQUIER producto de index.html cuyo id coincida
   con un producto scrapeado (vinos, licores, saborizadas, cervezas, etc.).

Uso:  python sync_mami.py          (o doble click en sync_mami.bat)
Solo usa la librería estándar de Python — no requiere pip install.
"""
import re
import json
import ssl
import urllib.request
import unicodedata
from pathlib import Path

# Windows suele no tener los certificados raiz para Python -> contexto sin verificacion
_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE

BASE = 'https://www.dinoonline.com.ar'
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml',
    'Accept-Language': 'es-AR,es;q=0.9',
}

# Categorías que alimentan el bloque de Golosinas (clave del tab -> slug)
GOLOSINAS_CATS = {
    'm_alfajores':  'supermami-almacen-golosinas-y-chocolates-alfajores',
    'm_chocolates': 'supermami-almacen-golosinas-y-chocolates-chocolates',
    'm_golosinas':  'supermami-almacen-golosinas-y-chocolates-golosinas',
    'm_obleas':     'supermami-almacen-golosinas-y-chocolates-obleas-y-turrones',
    'm_postre':     'supermami-almacen-golosinas-y-chocolates-postre-de-mani',
    'm_galletas_dulces':  'supermami-almacen-desayuno-galletas-dulces',
    'm_galletas_saladas': 'supermami-almacen-desayuno-galletas-saladas',
    'm_galletas_arroz':   'supermami-almacen-desayuno-galletas-de-arroz',
    'm_galletas_sinsal':  'supermami-almacen-desayuno-galletas-sin-sal',
}
# Tabs de GONDOLA alimentados por el Mami (varios slugs por tab)
GONDOLA_CATS = {
    'g_salchichas': ['supermami-fresco-quesos-y-fiambres-salchichas'],
    'g_yerba':      ['supermami-almacen-desayuno-yerba'],
    'g_untables':   ['supermami-fresco-quesos-y-fiambres-quesos-untables',
                     'supermami-almacen-dulces-dulce-de-leche',
                     'supermami-almacen-dulces-mermeladas-y-jaleas'],
    'g_latas':      ['supermami-almacen-conservas-conservas-de-carne',
                     'supermami-almacen-conservas-conservas-de-fruta',
                     'supermami-almacen-conservas-conservas-de-pescado',
                     'supermami-almacen-conservas-conservas-de-tomate',
                     'supermami-almacen-conservas-conservas-de-vegetales'],
}
# Prefijos de categorías extra solo para ACTUALIZAR PRECIOS de productos ya cargados
PRICE_SYNC_PREFIXES = ['supermami-bebidas-']

# Marcas del sitio con margen 15% (para actualizar precios de las cards de la heladera/botellas)
PRIMERAS_SITE = {'coca-cola','coca zero','sprite','sprite zero','fanta','fanta zero','schweppes','pepsi',
 'pepsi black','7up','paso de los toros','mirinda','crush','villavicencio','villa del sur','bon aqua',
 'cepita','aquarius','levite','h2oh','baggio / ades','pritty limon','quilmes','stella artois','heineken',
 'corona','andes','imperial','brahma','patagonia','budweiser','schneider','amstel','miller','red bull',
 'monster','speed','powerade','gatorade','rockstar','smirnoff','absolut','skyy','johnnie walker','jameson',
 'chivas regal','chivas',"jack daniel's",'j&b',"grant's","ballantine's",'bacardi','fernet branca','gancia',
 'campari','aperol','cinzano','martini','cynar',"gordon's",'marlboro','philip morris','camel','lucky strike',
 'chesterfield','parliament','rothmans','parisiennes'}

BRANDS = ['ARCOR','JORGITO','MOGUL','BON O BON','AGUILA','MILKA','BELDENT','TOP LINE',
 'MENTHOPLUS','TODDY','CHOCOARROZ','TATIN','MOGY','SOL SERRANO','CHOCMAN','CADBURY',
 'BLOCK','COFLER','GEORGALOS','RHODESIA','TITA','KINDER','FERRERO','SUGUS','MENTOS',
 'HALLS','FLYNN PAFF','ROCKLETS','BAZOOKA','PICO DULCE','LHERITIER','MISKY','BILLIKEN',
 'VAUQUITA','HAMLET','SHOT','TOFI','MARROC','CABSHA','DRF','BUBBALOO','TOPLINE','LIPO',
 'MANTECOL','GUAYMALLEN','FANTOCHE','PEPITOS','OREO','TERRABUSI','MALVAVISCOS','DOS EN UNO']


# ── MARGENES K24 ──────────────────────────────────────────────
# precio final = base Mami x (1 + margen) x (1 + COMISION_MP), redondeado a $50
COMISION_MP = 0.066
MARGEN_PRIMERAS = 0.15
MARGEN_RESTO = 0.25
PRIMERAS_MARCAS = {'milka','ferrero','kinder','oreo','arcor','aguila','bon o bon','cadbury','mogul',
 'beldent','sugus','toddy','terrabusi','tofi','shot','rocklets','mentos','halls','tita','rhodesia',
 'mantecol','top line','menthoplus'}

def precio_final(base, marca=''):
    m = MARGEN_PRIMERAS if (marca or '').strip().lower() in PRIMERAS_MARCAS else MARGEN_RESTO
    return int(round(base * (1 + m) * (1 + COMISION_MP) / 50.0)) * 50


def precio_final_site(base, marca_site=''):
    n = norm((marca_site or '')).strip().lower()
    m = MARGEN_PRIMERAS if n in PRIMERAS_SITE else MARGEN_RESTO
    return int(round(base * (1 + m) * (1 + COMISION_MP) / 50.0)) * 50


def norm(s):
    s = unicodedata.normalize('NFD', s)
    return ''.join(c for c in s if unicodedata.category(c) != 'Mn')


def title_case(s):
    small = {'de','la','el','los','las','y','con','sin','al','en','x','un','gr','kg','cc','ml','lt'}
    words = s.lower().split()
    out = []
    for i, w in enumerate(words):
        out.append(w if (w in small and i > 0) else w.capitalize())
    return ' '.join(out)


def fetch(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=45, context=_SSL_CTX) as r:
        return r.read().decode('utf-8', errors='replace')


def discover_categories(html):
    """slug -> N-code, desde el nav de la home"""
    cats = {}
    for m in re.finditer(r'/super/categoria/([a-z0-9-]+)/_/(N-[a-z0-9]+)', html, re.I):
        cats[m.group(1)] = m.group(2)
    return cats


def parse_products(html):
    """[(id, nombre, precio_int)] de una página de categoría"""
    out, seen = [], set()
    # cada producto: <div class="product"> ... /_/A-ID ... $precio ... class="description...">NOMBRE<
    for block in re.split(r'class="product"', html)[1:]:
        block = block[:4000]
        mid = re.search(r'/_/A-(\d+)', block)
        mpr = re.search(r'precio-unidad[^>]*>\s*<span[^>]*>\s*\$\s*([\d.,]+)', block)
        mnm = re.search(r'class="description[^"]*"[^>]*>\s*([^<]+)', block)
        if not (mid and mpr and mnm):
            continue
        pid = mid.group(1)
        if pid in seen:
            continue
        seen.add(pid)
        precio = int(round(float(mpr.group(1).replace(',', ''))))
        nombre = mnm.group(1).strip()
        out.append((pid, nombre, precio))
    return out


def brand_of(nombre):
    n = norm(nombre).upper()
    for b in BRANDS:
        if b in n:
            return title_case(b)
    return ''


def main():
    idx_path = Path(__file__).parent / 'index.html'
    src = idx_path.read_text(encoding='utf-8')

    print('Descubriendo categorías del Mami...')
    home = fetch(BASE + '/super/home')
    cats = discover_categories(home)
    print(f'  {len(cats)} categorías encontradas en el nav')

    # ── 1. GOLOSINAS: regenerar bloque completo ──
    golos = {}
    total = 0
    for key, slug in GOLOSINAS_CATS.items():
        ncode = cats.get(slug)
        if not ncode:
            print(f'  ⚠ no encontré {slug} en el nav, salteo')
            golos[key] = []
            continue
        url = f'{BASE}/super/categoria/{slug}/_/{ncode}?No=0&Nrpp=500'
        items = parse_products(fetch(url))
        golos[key] = items
        total += len(items)
        print(f'  {key}: {len(items)} productos')
    print(f'GOLOSINAS TOTAL: {total}')

    if total > 100:  # sanity check antes de pisar el bloque
        js_items = {}
        for key, items in golos.items():
            arr = []
            for pid, nombre, precio in items:
                marca = brand_of(nombre)
                arr.append({
                    'id': pid, 'name': title_case(nombre), 'brand': marca,
                    'cat': '', 'price': precio_final(precio, marca),
                    'img': f'https://statics.dinoonline.com.ar/imagenes/full_600x600_ma/{pid}_f.jpg',
                })
            js_items[key] = arr
        bloque = ('// MAMI-AUTOGEN-START (no editar a mano: lo regenera sync_mami.py)\n'
                  'const catalogGolosinasMami = ' + json.dumps(js_items, ensure_ascii=False) + ';\n'
                  '// MAMI-AUTOGEN-END')
        nuevo = re.sub(r'// MAMI-AUTOGEN-START.*?// MAMI-AUTOGEN-END', bloque, src, flags=re.S)
        if nuevo == src:
            print('⚠ no encontré los marcadores MAMI-AUTOGEN en index.html')
        else:
            src = nuevo
            print('✔ bloque catalogGolosinasMami regenerado')
    else:
        print('⚠ muy pocos productos, NO piso el bloque de golosinas')

    # ── 1b. GONDOLA MAMI: salchichas / yerba / untables / latas ──
    bases = {}   # pid -> precio base del Mami (sin margen)
    for key, items in golos.items():
        for pid, _, precio in items:
            bases[pid] = precio
    gtotal = 0
    gjs = {}
    for key, slugs in GONDOLA_CATS.items():
        arr = []
        for slug in slugs:
            ncode = cats.get(slug)
            if not ncode:
                print(f'  ⚠ no encontré {slug}, salteo')
                continue
            for pid, nombre, precio in parse_products(fetch(f'{BASE}/super/categoria/{slug}/_/{ncode}?No=0&Nrpp=500')):
                bases[pid] = precio
                arr.append({
                    'id': pid, 'name': title_case(nombre), 'brand': brand_of(nombre), 'cat': '',
                    'price': precio_final(precio, brand_of(nombre)),
                    'img': f'https://statics.dinoonline.com.ar/imagenes/full_600x600_ma/{pid}_f.jpg',
                })
        gjs[key] = arr
        gtotal += len(arr)
        print(f'  {key}: {len(arr)} productos')
    print(f'GONDOLA MAMI TOTAL: {gtotal}')
    if gtotal > 30:
        gbloque = ('// MAMI-GONDOLA-AUTOGEN-START (no editar a mano)\n'
                   'const catalogGondolaMami = ' + json.dumps(gjs, ensure_ascii=False) + ';\n'
                   '// MAMI-GONDOLA-AUTOGEN-END')
        nuevo = re.sub(r'// MAMI-GONDOLA-AUTOGEN-START.*?// MAMI-GONDOLA-AUTOGEN-END', gbloque, src, flags=re.S)
        if nuevo != src:
            src = nuevo
            print('✔ bloque catalogGondolaMami regenerado')
        else:
            print('⚠ no encontré los marcadores MAMI-GONDOLA-AUTOGEN')
    else:
        print('⚠ muy pocos productos de gondola, NO piso el bloque')

    # ── 1c. FRESCO MAMI: lácteos / quesos y fiambres / pizzas ──
    # Categorías padre (traen todas las subcategorías con Nrpp alto)
    FRESCO_CATS = {
        'm_lacteos':         ['supermami-fresco-lacteos'],
        'm_quesos_fiambres': ['supermami-fresco-quesos-y-fiambres'],
        'm_pizzas':          ['supermami-fresco-pizzas-y-prepizzas'],
    }
    fresco_raw = {}
    ftotal = 0
    for key, slugs in FRESCO_CATS.items():
        arr, seen = [], set()
        for slug in slugs:
            ncode = cats.get(slug)
            if not ncode:
                print(f'  ⚠ no encontré {slug}, salteo')
                continue
            for pid, nombre, precio in parse_products(fetch(f'{BASE}/super/categoria/{slug}/_/{ncode}?No=0&Nrpp=600')):
                if pid in seen:
                    continue
                # descartar precios claramente erróneos del Mami (> $500k base)
                if precio > 500000:
                    continue
                # en pizzas, sólo dejar pizzas/prepizzas (a veces cuela algún queso)
                if key == 'm_pizzas' and 'pizza' not in norm(nombre).lower():
                    continue
                seen.add(pid)
                bases[pid] = precio
                arr.append([pid, title_case(nombre), precio_final(precio, brand_of(nombre))])
        fresco_raw[key] = arr
        ftotal += len(arr)
        print(f'  {key}: {len(arr)} productos')
    print(f'FRESCO MAMI TOTAL: {ftotal}')
    if ftotal > 200:  # sanity check antes de pisar
        fbloque = ('// MAMI-FRESCO-AUTOGEN-START (no editar a mano: lo regenera sync_mami.py)\n'
                   'const _frescoRawMami = ' + json.dumps(fresco_raw, ensure_ascii=False, separators=(',', ':')) + ';\n'
                   'const catalogFrescoMami = Object.fromEntries(Object.entries(_frescoRawMami).map(function(e){\n'
                   "  return [e[0], e[1].map(function(p){ return {id:p[0], name:p[1], brand:'', cat:'', price:p[2],\n"
                   "    img:'https://statics.dinoonline.com.ar/imagenes/full_600x600_ma/'+p[0]+'_f.jpg'}; })];\n"
                   '}));\n'
                   '// MAMI-FRESCO-AUTOGEN-END')
        nuevo = re.sub(r'// MAMI-FRESCO-AUTOGEN-START.*?// MAMI-FRESCO-AUTOGEN-END', fbloque, src, flags=re.S)
        if nuevo != src:
            src = nuevo
            print('✔ bloque catalogFrescoMami regenerado')
        else:
            print('⚠ no encontré los marcadores MAMI-FRESCO-AUTOGEN')
    else:
        print('⚠ muy pocos productos de fresco, NO piso el bloque')

    # ── 2. PRICE SYNC: todas las bebidas + golosinas por id ──
    precios = {}
    for key, items in golos.items():
        for pid, nombre, precio in items:
            precios[pid] = precio_final(precio, brand_of(nombre))
    # Crawl: arranca con las categorías de bebidas del nav de la home y va
    # descubriendo las que faltan (ej: aguas) desde el menú lateral de cada
    # página scrapeada, para no depender solo del nav de la home.
    pendientes = [s for s in cats if any(s.startswith(p) for p in PRICE_SYNC_PREFIXES)]
    hechas = set()
    print(f'Precio-sync: arrancando con {len(pendientes)} categorías de bebidas...')
    while pendientes:
        slug = pendientes.pop()
        if slug in hechas or slug not in cats:
            continue
        hechas.add(slug)
        try:
            html = fetch(f'{BASE}/super/categoria/{slug}/_/{cats[slug]}?No=0&Nrpp=500')
            # cosechar categorías hermanas del nav de esta página
            for s2, nc in discover_categories(html).items():
                if s2 not in cats:
                    cats[s2] = nc
                if any(s2.startswith(p) for p in PRICE_SYNC_PREFIXES) and s2 not in hechas:
                    pendientes.append(s2)
            for pid, _, precio in parse_products(html):
                precios[pid] = precio_final(precio)  # bebidas sueltas: margen resto
                bases[pid] = precio
        except Exception as e:
            print(f'  ⚠ {slug}: {e}')
    print(f'  bebidas: {len(hechas)} categorías, {len(precios)} precios de referencia')

    actualizados = 0
    def actualizar(m):
        nonlocal actualizados
        pid, viejo = m.group(2), int(m.group(3))
        nuevo_p = precios.get(pid)
        if nuevo_p and nuevo_p != viejo:
            actualizados += 1
            return m.group(1) + str(nuevo_p)
        return m.group(0)
    src = re.sub(r"(\{id:'(\d{6,8})'[^{}]*?price:)(\d+)", actualizar, src)
    print(f'✔ {actualizados} precios actualizados en index.html')

    # ── 3. BRAND CARDS: actualizar variantes por el id de su imagen del Dino ──
    act_cards = 0
    pi = src.find('  promos: [')
    pj = src.find('  botellas: [', pi)
    spans = []
    for m in re.finditer(r'variants:\s*\[', src):
        a = m.end(); depth = 1; k = a
        while depth:
            c = src[k]
            if c == '[': depth += 1
            elif c == ']': depth -= 1
            k += 1
        if pi < m.start() < pj:
            continue  # promos: no tocar
        back = src[max(0, m.start()-40000):m.start()]
        nm = re.findall(r"name:'((?:\\'|[^'])+)'", back)
        if not nm:
            continue
        marca = nm[-1].replace("\\'", "'")
        spans.append((a, k, marca))
    def _upd_variant(mm, marca):
        nonlocal act_cards
        pid = mm.group(2)
        if pid in bases:
            nuevo_p = precio_final_site(bases[pid], marca)
            if nuevo_p != int(mm.group(1)):
                act_cards += 1
                return 'price:' + str(nuevo_p) + mm.group(0)[mm.end(1)-mm.start(0):]
        return mm.group(0)
    for a, k, marca in reversed(spans):
        seg = src[a:k]
        seg2 = re.sub(r"price:(\d+),\s*img:'[^']*?/(\d+)_[fm]\.jpg'",
                      lambda mm: _upd_variant(mm, marca), seg)
        src = src[:a] + seg2 + src[k:]
    print(f'✔ {act_cards} precios de cards de marca actualizados (heladera/botellas/cigarrillos no, solo con img del Dino)')

    idx_path.write_text(src, encoding='utf-8')
    print('\nLISTO. Ahora corré push_solo.bat para deployar (o sync_mami.bat ya lo hace solo).')


if __name__ == '__main__':
    main()
