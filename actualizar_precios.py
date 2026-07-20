# -*- coding: utf-8 -*-
"""
actualizar_precios.py — Trae los precios de las páginas de los proveedores
(Super Mami / dinoonline y Distribuidora del Centro / Pedix) y actualiza
SOLO la columna "Costo" de la planilla "precios editable google".

Los márgenes que pusiste NO se tocan: el Precio Sugerido se recalcula solo
con la fórmula de la planilla, y la web lo toma en ~2 minutos.

Los productos que ya no aparecen en la página del proveedor quedan Activo = NO
(o sea, desaparecen de la web). Si el scrapeo sale mal y trae mucho menos de lo
esperado, el script ABORTA esa parte y no desactiva nada.

Deja un reporte en cambios_precios.csv con todo lo que cambió.
"""
import json, re, ssl, sys, time, urllib.request, io
from pathlib import Path

EXEC = 'https://script.google.com/macros/s/AKfycbz48Hs8pcO-ewcmnxaHrS-eBrcVk-llMdaCxjNyCXOdP99SahO7X84w-97bs_JvuzOL/exec'
API_PRECIOS = 'https://k24hs.com/api/precios'
BASE = 'https://www.dinoonline.com.ar'
PEDIX = 'https://pedix.app/cigarreria-y-distribuidora-del-centro'

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/126.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml',
    'Accept-Language': 'es-AR,es;q=0.9',
}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

LOTE = 400
NRPP = 500
# Si el scrapeo trae menos de este porcentaje de lo que esperábamos, no desactivamos nada.
UMBRAL_SEGURIDAD = 0.60


def log(*a):
    print(*a, flush=True)


def fetch(url, timeout=45):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        return r.read().decode('utf-8', errors='replace')


def post(payload, timeout=180):
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(EXEC, data=data, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
        return json.loads(r.read().decode('utf-8', errors='replace'))


# ─────────────────────────── Super Mami ───────────────────────────
def descubrir_categorias():
    """slug -> N-code, recorriendo el nav del sitio."""
    cats = {}
    paginas = [BASE + '/super', BASE + '/super/categoria/almacen',
               BASE + '/super/categoria/bebidas', BASE + '/super/categoria/limpieza',
               BASE + '/super/categoria/perfumeria', BASE + '/super/categoria/fresco']
    for p in paginas:
        try:
            html = fetch(p)
        except Exception as e:
            log('   (no pude abrir %s: %s)' % (p, e))
            continue
        for m in re.finditer(r'/super/categoria/([a-z0-9-]+)/_/(N-[a-z0-9]+)', html, re.I):
            cats[m.group(1)] = m.group(2)
    return cats


def a_numero(txt):
    """'1,234.50' y '1.234,50' -> 1234. El último separador es el decimal."""
    s = str(txt).strip()
    ic, ip = s.rfind(','), s.rfind('.')
    if ic == -1 and ip == -1:
        limpio = s
    elif ic > ip:                     # coma decimal (formato argentino)
        limpio = s[:ic].replace('.', '').replace(',', '') + '.' + s[ic + 1:]
    else:                             # punto decimal (formato inglés)
        limpio = s[:ip].replace(',', '').replace('.', '') + '.' + s[ip + 1:]
    # un separador solo, con 3 dígitos detrás, es separador de miles (1.234 = mil doscientos)
    m = re.fullmatch(r'(\d+)\.(\d{3})', limpio)
    if m and (ic == -1 or ip == -1):
        limpio = m.group(1) + m.group(2)
    return int(round(float(limpio)))


def parse_products(html):
    """[(id, nombre, precio)] de una página de categoría."""
    out, seen = [], set()
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
        try:
            precio = a_numero(mpr.group(1))
        except (ValueError, TypeError):
            continue
        out.append((pid, mnm.group(1).strip(), precio))
    return out


def scrapear_mami():
    log('\n== Super Mami ==')
    cats = descubrir_categorias()
    log('   %d categorías encontradas' % len(cats))
    precios, nombres = {}, {}
    for i, (slug, ncode) in enumerate(sorted(cats.items()), 1):
        off, total_cat = 0, 0
        while True:
            url = '%s/super/categoria/%s/_/%s?No=%d&Nrpp=%d' % (BASE, slug, ncode, off, NRPP)
            try:
                prods = parse_products(fetch(url))
            except Exception:
                break
            for pid, nom, pr in prods:
                if pr > 0:
                    precios[pid] = pr
                    nombres[pid] = nom
            total_cat += len(prods)
            if len(prods) < NRPP:
                break
            off += NRPP
            time.sleep(0.2)
        if i % 10 == 0 or total_cat:
            log('   [%3d/%3d] %-58s %4d' % (i, len(cats), slug[:58], total_cat))
        time.sleep(0.15)
    log('   TOTAL Mami: %d productos con precio' % len(precios))
    return precios, nombres


# ────────────────────── Distribuidora (Pedix) ──────────────────────
def _norm_nombre(s):
    s = str(s).upper()
    for a, b in (('Á', 'A'), ('É', 'E'), ('Í', 'I'), ('Ó', 'O'), ('Ú', 'U'), ('Ñ', 'N')):
        s = s.replace(a, b)
    return re.sub(r'[^A-Z0-9]+', ' ', s).strip()


def nuestros_distri():
    """id -> nombre, leídos del bloque DISTRI-AUTOGEN del index.html."""
    try:
        html = (Path(__file__).parent / 'index.html').read_text(encoding='utf-8', errors='replace')
    except Exception:
        return {}
    i, j = html.find('DISTRI-AUTOGEN-START'), html.find('DISTRI-AUTOGEN-END')
    if i == -1 or j == -1:
        return {}
    return {m.group(1): m.group(2)
            for m in re.finditer(r'\["(d-[^"]+)","([^"]+)",(\d+)', html[i:j])}


def scrapear_pedix():
    """La Distribuidora rehízo su catálogo: los IDs cambiaron, así que cruzamos
    por nombre contra los productos que tenemos cargados."""
    log('\n== Distribuidora del Centro (Pedix) ==')
    precios, nombres = {}, {}
    try:
        html = fetch(PEDIX, timeout=60)
    except Exception as e:
        log('   No pude abrir la página: %s' % e)
        return precios, nombres
    m = re.search(r'<script[^>]*id="ng-state"[^>]*>(.*?)</script>', html, re.S | re.I)
    if not m:
        log('   No encontré el catálogo en la página (habrá cambiado de formato).')
        return precios, nombres
    try:
        data = json.loads(m.group(1))
    except Exception as e:
        log('   No pude leer el catálogo: %s' % e)
        return precios, nombres

    cats = (data.get('app-request-context-state', {}).get('catalog', {}).get('categories') or [])
    por_nombre = {}
    for c in cats:
        for p in (c.get('products') or []):
            if not isinstance(p, dict):
                continue
            pr = p.get('price')
            if not pr:                                  # si no tiene precio propio, la presentación más barata
                pres = p.get('presentations') or {}
                vals = pres.values() if isinstance(pres, dict) else pres
                cands = [x.get('price') for x in vals if isinstance(x, dict) and x.get('price')]
                pr = min(cands) if cands else None
            if pr:
                try:
                    por_nombre[_norm_nombre(p.get('name', ''))] = int(round(float(pr)))
                except (TypeError, ValueError):
                    pass
    log('   %d productos con precio en la página' % len(por_nombre))

    tengo = nuestros_distri()
    if not tengo:
        log('   No pude leer nuestros productos del index.html.')
        return precios, nombres
    for fid, nom in tengo.items():
        v = por_nombre.get(_norm_nombre(nom))
        if v:
            precios[fid] = v
            nombres[fid] = nom
    log('   TOTAL Distribuidora: %d de %d productos encontrados' % (len(precios), len(tengo)))
    return precios, nombres


# ─────────────────────────── Principal ───────────────────────────
def id_mami(fila_id):
    """Devuelve el id numérico de dinoonline, o None si no es del Mami."""
    s = str(fila_id)
    if re.fullmatch(r'\d+', s):
        return s
    m = re.fullmatch(r'(?:prod|dn-)(\d+)', s)
    return m.group(1) if m else None


def main():
    log('Bajando la lista de productos de la planilla...')
    filas = json.loads(fetch(API_PRECIOS, timeout=90))['items']
    log('   %d filas en la planilla' % len(filas))

    esperados_mami = [f for f in filas if id_mami(f[0])]
    esperados_pedix = [f for f in filas if str(f[0]).startswith('d-')]
    log('   %d del Mami · %d de la Distribuidora · %d tarjetas de marca (no se tocan)'
        % (len(esperados_mami), len(esperados_pedix), len(filas) - len(esperados_mami) - len(esperados_pedix)))

    solo_distri = '--solo-distri' in sys.argv
    if solo_distri:
        log('\n(modo solo Distribuidora: no toco el Mami)')
        pm, nm = {}, {}
    else:
        pm, nm = scrapear_mami()
    pp, np_ = scrapear_pedix()

    # ── cruce ──
    actualizar, faltantes, reporte = [], [], []
    for f in filas:
        fid = str(f[0])
        num = id_mami(fid)
        if num is not None:
            fuente, nuevo, nom = 'mami', pm.get(num), nm.get(num, '')
        elif fid.startswith('d-'):
            fuente, nuevo, nom = 'distri', pp.get(fid), np_.get(fid, '')
        else:
            continue
        if nuevo is None:
            faltantes.append((fid, fuente))
        else:
            actualizar.append([fid, nuevo])
            reporte.append((fid, fuente, nom, nuevo))

    log('\n== Resumen ==')
    log('   %d costos para actualizar' % len(actualizar))
    log('   %d no aparecieron en la página' % len(faltantes))

    # ── salvaguarda ──
    ok_mami = len(pm) >= UMBRAL_SEGURIDAD * len(esperados_mami)
    ok_pedix = len(pp) >= UMBRAL_SEGURIDAD * len(esperados_pedix)
    if not ok_mami and not solo_distri:
        log('   ⚠ El Mami trajo muy poco (%d de ~%d). No desactivo nada de esa fuente.'
            % (len(pm), len(esperados_mami)))
    if not ok_pedix:
        log('   ⚠ La Distribuidora trajo muy poco (%d de ~%d). No desactivo nada de esa fuente.'
            % (len(pp), len(esperados_pedix)))

    if not actualizar:
        log('\nNo hay nada para actualizar. Reviso que las páginas estén andando y salgo.')
        return

    # ── escribir costos ──
    log('\nActualizando la columna Costo...')
    tot_act = tot_igual = 0
    for i in range(0, len(actualizar), LOTE):
        r = post({'action': 'precios_costos', 'rows': actualizar[i:i + LOTE]})
        tot_act += r.get('actualizados', 0)
        tot_igual += r.get('sinCambio', 0)
        log('   %d/%d' % (min(i + LOTE, len(actualizar)), len(actualizar)))
        time.sleep(0.4)
    log('   %d costos cambiaron · %d ya estaban igual' % (tot_act, tot_igual))

    # ── desactivar faltantes ──
    a_desactivar = [fid for fid, fu in faltantes
                    if (fu == 'mami' and ok_mami) or (fu == 'distri' and ok_pedix)]
    if a_desactivar:
        log('\nMarcando Activo = NO a %d productos que ya no están...' % len(a_desactivar))
        for i in range(0, len(a_desactivar), LOTE):
            post({'action': 'precios_activo', 'ids': a_desactivar[i:i + LOTE], 'activo': 'NO'})
            time.sleep(0.4)
        log('   listo')

    # ── reporte ──
    out = Path(__file__).parent / 'cambios_precios.csv'
    with io.open(out, 'w', encoding='utf-8-sig', newline='') as fh:
        fh.write('ID;Fuente;Producto;CostoNuevo\n')
        for fid, fu, nom, pr in reporte:
            fh.write('%s;%s;%s;%d\n' % (fid, fu, str(nom).replace(';', ','), pr))
        fh.write('\nID;Fuente;NO ENCONTRADO\n')
        for fid, fu in faltantes:
            fh.write('%s;%s;no aparece en la pagina\n' % (fid, fu))
    log('\nReporte: %s' % out)
    log('Los precios nuevos se ven en k24hs.com en ~2 minutos.')


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        log('\nERROR: %s' % e)
        sys.exit(1)
