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

# ─────────────────────── PRECIOS ANCLA ───────────────────────
#  Son los precios que la gente mira primero para decidir si un kiosco
#  es caro o barato. Si se mueven solos, se mueve la idea que el cliente
#  se hace de TODO el catalogo. Por eso el actualizador no los toca.
#
#  Igual sale a buscar el costo del proveedor y lo informa al final, asi
#  el margen real queda a la vista sin que cambie el precio de gondola.
#  Cuando quieras moverlos, los movés vos, a mano y sabiendo.
#
#  Para sumar o sacar uno, agregá o borrá su id de esta lista.
#  Los cigarrillos NO hacen falta: no tienen proveedor mapeado, asi que
#  el actualizador nunca los tocó ni los va a tocar.
ANCLAS = {
    'd-AW8rAxhHKj7II2Xg-cn3E',                                     # Fernet Branca 750 (Distribuidora)
    'fernet-branca__1', 'fernet-branca__2',                        # Fernet Branca (tarjeta de marca)
    'fernet-1882__1', 'fernet-1882__2',                            # Fernet 1882
    'coca-cola__2', 'coca-cola__3', 'coca-cola__5',
    'coca-cola__6', 'coca-cola__9',                                # Coca-Cola
    'coca-zero__2', 'coca-zero__3', 'coca-zero__4', 'coca-zero__5',  # Coca Zero
}

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


# La consola de Windows abre en cp1252 y no sabe escribir "⚠", "·" ni las
# tildes. Un print con uno de esos caracteres tira UnicodeEncodeError y mata
# la corrida entera — paso de verdad: una noche el script actualizo los 4548
# costos y despues murio imprimiendo un "⚠", quedando marcado como FALLO.
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def log(*a):
    """Nunca puede hacer fallar la corrida: si la consola no sabe escribir
    un caracter, se reemplaza y se sigue."""
    try:
        print(*a, flush=True)
    except UnicodeEncodeError:
        cod = getattr(sys.stdout, 'encoding', None) or 'ascii'
        limpio = [str(x).encode(cod, errors='replace').decode(cod, errors='replace') for x in a]
        print(*limpio, flush=True)
    except Exception:
        pass


def Number_(x):
    try:
        return float(x) or 0
    except (TypeError, ValueError):
        return 0


def fetch(url, timeout=45, reintentos=3):
    """GET con reintentos: en la nube una falla de red puntual es normal."""
    ultimo = None
    for intento in range(reintentos):
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
                return r.read().decode('utf-8', errors='replace')
        except Exception as e:
            ultimo = e
            if intento < reintentos - 1:
                time.sleep(2 * (intento + 1))
    raise ultimo


def secreto_planilla():
    """El secreto que autoriza a tocar la planilla.

    Vive en secreto_planilla.txt, al lado de este script, y ese archivo esta
    en .gitignore: no se sube a GitHub. El mismo valor va cargado en el Apps
    Script, en Configuracion del proyecto > Propiedades del script, con el
    nombre K24_SECRETO.

    Si el archivo no existe no pasa nada: el Apps Script tampoco exige nada
    mientras no tenga la propiedad cargada.
    """
    p = Path(__file__).parent / 'secreto_planilla.txt'
    try:
        return p.read_text(encoding='utf-8').strip()
    except Exception:
        return ''


def post(payload, timeout=180, reintentos=4):
    """POST con reintentos.

    Antes no los tenia, y como la corrida son ~20 minutos de lotes contra
    Apps Script, un solo hipo de red la mataba entera. Paso de verdad:
    "SSL: UNEXPECTED_EOF_WHILE_READING" en el lote 4400 de 4555, con los
    4400 anteriores ya escritos en la planilla.

    Reintentar es seguro: las acciones de la planilla ASIGNAN valores
    (poner tal costo en tal fila), no acumulan. Repetir un lote deja el
    mismo resultado que aplicarlo una sola vez.
    """
    s = secreto_planilla()
    if s:
        payload = dict(payload, secreto=s)
    data = json.dumps(payload).encode('utf-8')
    ultimo = None
    for intento in range(reintentos):
        try:
            req = urllib.request.Request(EXEC, data=data,
                                         headers={'Content-Type': 'application/json'})
            with urllib.request.urlopen(req, timeout=timeout, context=CTX) as r:
                return json.loads(r.read().decode('utf-8', errors='replace'))
        except Exception as e:
            ultimo = e
            if intento < reintentos - 1:
                espera = 3 * (intento + 1)
                log('   (reintento %d/%d en %ds: %s)' % (intento + 2, reintentos, espera, e))
                time.sleep(espera)
    raise ultimo


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


def _unidades_de(etiqueta):
    """Cuántas unidades trae una presentación, leyendo su nombre.

    La Distribuidora no publica un precio por producto: publica formatos.
    'Precio x carton (10 etiquetas)' = 10, 'Precio x unidad' = 1, etc.
    Devuelve None si no se entiende la etiqueta, para no inventar nada.
    """
    s = str(etiqueta or '').lower()
    if re.search(r'\bmedio\s*carton\b', s):
        return 5
    if re.search(r'\bcarton\b', s):
        return 10
    m = re.search(r'(?:x|de)\s*(\d+)\s*(?:uni|unidades|etiquetas)', s)
    if m:
        return int(m.group(1))
    m = re.search(r'pack\s*de\s*(\d+)', s)
    if m:
        return int(m.group(1))
    if re.search(r'x\s*(?:1\s*)?(?:unidad|uni)\b', s):
        return 1
    return None                                  # bultos, bidones, cosas raras


def _precio_unitario(p):
    """Costo de UNA unidad.

    Antes se leía solo p['price'] y, si no estaba, se buscaba dentro de
    'presentations' un campo price. Pero los precios no viven ahí: viven en
    presentations['items']. Por eso 449 de los 720 productos de la
    Distribuidora quedaban invisibles, entre ellos los 96 cigarrillos.

    Se prefiere el precio por unidad suelta. Si no existe, se usa el formato
    más chico disponible: es el costo más alto y por lo tanto el mas prudente
    para calcular el margen. Nunca el mayorista, que da un costo optimista.
    """
    directo = p.get('price')
    if directo:
        try:
            return float(directo)
        except (TypeError, ValueError):
            pass

    pres = p.get('presentations') or {}
    items = pres.get('items') if isinstance(pres, dict) else None
    if not isinstance(items, list):
        return None

    por_unidad, mas_chico, cant_chica = None, None, None
    for it in items:
        if not isinstance(it, dict) or not it.get('price'):
            continue
        n = _unidades_de(it.get('name'))
        if not n:
            continue
        try:
            unit = float(it['price']) / n
        except (TypeError, ValueError, ZeroDivisionError):
            continue
        if n == 1:
            por_unidad = unit if por_unidad is None else min(por_unidad, unit)
        if cant_chica is None or n < cant_chica:
            cant_chica, mas_chico = n, unit
    return por_unidad if por_unidad is not None else mas_chico


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
            pr = _precio_unitario(p)
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
def cargar_mapa_marcas():
    """Tarjetas de marca (coca-cola__1, quilmes__2...) -> id del producto en el Mami.
    Sin esto esas filas nunca se actualizarían, porque no tienen id de proveedor."""
    p = Path(__file__).parent / 'mapa_marcas.json'
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text(encoding='utf-8'))
    except Exception as e:
        log('   (no pude leer mapa_marcas.json: %s)' % e)
        return {}


MAPA_MARCAS = {}


def id_mami(fila_id):
    """Devuelve el id numérico de dinoonline, o None si no es del Mami."""
    s = str(fila_id)
    if re.fullmatch(r'\d+', s):
        return s
    m = re.fullmatch(r'(?:prod|dn-)(\d+)', s)
    if m:
        return m.group(1)
    return MAPA_MARCAS.get(s)          # tarjetas de marca


def main():
    global MAPA_MARCAS
    MAPA_MARCAS = cargar_mapa_marcas()

    log('Bajando la lista de productos de la planilla...')
    filas = json.loads(fetch(API_PRECIOS, timeout=90))['items']
    log('   %d filas en la planilla' % len(filas))

    esperados_mami = [f for f in filas if id_mami(f[0])]
    esperados_pedix = [f for f in filas if str(f[0]).startswith('d-')]
    tarjetas = sum(1 for f in filas if '__' in str(f[0]) and str(f[0]) in MAPA_MARCAS)
    sin_tocar = len(filas) - len(esperados_mami) - len(esperados_pedix)
    log('   %d del Mami (incluye %d tarjetas de marca) · %d de la Distribuidora'
        % (len(esperados_mami), tarjetas, len(esperados_pedix)))
    log('   %d filas sin proveedor (promos, cigarrillos, etc): no se tocan' % sin_tocar)

    solo_distri = '--solo-distri' in sys.argv
    if solo_distri:
        log('\n(modo solo Distribuidora: no toco el Mami)')
        pm, nm = {}, {}
    else:
        pm, nm = scrapear_mami()
    pp, np_ = scrapear_pedix()

    # ── cruce ──
    actualizar, faltantes, reporte, anclas = [], [], [], []
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
            continue
        if fid in ANCLAS:
            # Se mira, se informa, no se toca.
            anclas.append((fid, nom, nuevo, Number_(f[2]) or Number_(f[1])))
            continue
        actualizar.append([fid, nuevo])
        reporte.append((fid, fuente, nom, nuevo))

    log('\n== Resumen ==')
    log('   %d costos para actualizar' % len(actualizar))
    log('   %d no aparecieron en la página' % len(faltantes))

    if anclas:
        log('\n== Anclas: NO se tocan, solo se informan ==')
        log('   %-34s %10s %10s %8s' % ('producto', 'costo', 'tu precio', 'margen'))
        for fid, nom, costo, precio in sorted(anclas, key=lambda a: -(a[3] or 0)):
            etiqueta = (nom or fid)[:34]
            if precio > 0:
                m = 100.0 * (precio - costo) / precio
                aviso = '  <-- POR DEBAJO DEL COSTO' if costo > precio else ''
                log('   %-34s %10s %10s %7.0f%%%s'
                    % (etiqueta, '$%d' % costo, '$%d' % precio, m, aviso))
            else:
                log('   %-34s %10s %10s %8s' % (etiqueta, '$%d' % costo, '-', '-'))

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
        log('\nERROR: no se pudo leer ningún precio de las páginas de los proveedores.')
        log('Puede ser que estén caídas o que hayan bloqueado el acceso. NO se tocó nada.')
        sys.exit(1)   # falla visible: GitHub avisa por mail

    # ── modo simulación: mostrar qué cambiaría, sin tocar nada ──
    if '--simular' in sys.argv:
        actual = {str(f[0]): (Number_(f[2]) or Number_(f[1])) for f in filas}
        cambios = []
        for fid, costo in actualizar:
            hoy = actual.get(fid) or 0
            if hoy > 0:
                nuevo_aprox = costo * 1.3325            # margen 25% + MP, aproximado
                d = round(100 * (nuevo_aprox - hoy) / hoy)
                if abs(d) >= 10:
                    cambios.append((abs(d), fid, hoy, round(nuevo_aprox), d))
        cambios.sort(reverse=True)
        log('\n===== SIMULACION (no se toco nada) =====')
        log('%d productos cambiarian de precio mas de 10%%:' % len(cambios))
        for _, fid, hoy, nue, d in cambios[:40]:
            log('   %-28s $%-8s -> $%-8s (%+d%%)' % (fid[:28], hoy, nue, d))
        if len(cambios) > 40:
            log('   ... y %d mas' % (len(cambios) - 40))
        log('\nPara aplicarlo de verdad, corre el script sin --simular.')
        return

    # ── escribir costos ──
    log('\nActualizando la columna Costo...')
    tot_act = tot_igual = tot_frenados = 0
    frenados = []
    for i in range(0, len(actualizar), LOTE):
        r = post({'action': 'precios_costos', 'rows': actualizar[i:i + LOTE]})
        tot_act += r.get('actualizados', 0)
        tot_igual += r.get('sinCambio', 0)
        tot_frenados += r.get('frenados', 0)
        frenados += r.get('detalleFrenados', []) or []
        log('   %d/%d' % (min(i + LOTE, len(actualizar)), len(actualizar)))
        time.sleep(0.4)
    log('   %d costos cambiaron · %d ya estaban igual' % (tot_act, tot_igual))
    if tot_frenados:
        log('   ⚠ %d NO se aplicaron: el precio saltaba mas de 30%% (revisar a mano).' % tot_frenados)

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
        if frenados:
            fh.write('\nID;FRENADO (salto > 30%);PrecioActual;PrecioNuevo\n')
            for f in frenados:
                fh.write('%s;revisar a mano;%s;%s\n' % (f.get('id', ''), f.get('de', ''), f.get('a', '')))
    log('\nReporte: %s' % out)
    if frenados:
        log('%d productos frenados por salto grande (ver cambios_precios.csv):' % len(frenados))
        for f in frenados[:15]:
            log('   %-28s $%s -> $%s' % (str(f.get('id',''))[:28], f.get('de',''), f.get('a','')))
    log('Los precios nuevos se ven en k24hs.com en ~2 minutos.')


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        log('\nERROR: %s' % e)
        sys.exit(1)
