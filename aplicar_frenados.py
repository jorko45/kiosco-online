# -*- coding: utf-8 -*-
"""
aplicar_frenados.py — Aplica los costos que el actualizador dejó frenados.

QUÉ ES UN "FRENADO"
actualizar_precios.py tiene un freno de seguridad: si un costo nuevo movería
el precio de venta más de 30%, NO lo aplica y lo anota aparte. Está para
atajar errores del scrapeo (que haya matcheado el producto equivocado), no
para bloquear cambios reales de precio.

Este script toma esos casos del último cambios_precios.csv y los aplica de
verdad, mandando tope=0 para desactivar el freno.

IMPORTANTE: no vuelve a scrapear nada. Usa exactamente los costos que ya
están en el CSV, que es lo que el humano revisó. Si querés datos frescos,
corré actualizar_precios.py primero.

Uso:
    python aplicar_frenados.py             ← aplica
    python aplicar_frenados.py --simular   ← solo muestra qué haría
"""
import io, json, ssl, sys, time, urllib.request
from pathlib import Path

EXEC = ('https://script.google.com/macros/s/'
        'AKfycbz48Hs8pcO-ewcmnxaHrS-eBrcVk-llMdaCxjNyCXOdP99SahO7X84w-97bs_JvuzOL/exec')

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

LOTE = 200

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass


def log(*a):
    try:
        print(*a, flush=True)
    except UnicodeEncodeError:
        cod = getattr(sys.stdout, 'encoding', None) or 'ascii'
        print(*[str(x).encode(cod, 'replace').decode(cod, 'replace') for x in a], flush=True)


def post(payload, timeout=180, reintentos=4):
    """Mismo criterio que actualizar_precios.py: reintentar es seguro porque
    la planilla ASIGNA valores, no acumula."""
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


def leer_csv(ruta):
    """Devuelve (costos_por_id, frenados) leyendo las tres secciones del CSV."""
    costos, frenados, modo = {}, [], None
    for l in io.open(ruta, encoding='utf-8-sig').read().split('\n'):
        if l.startswith('ID;Fuente;Producto'):      modo = 'cambios'; continue
        if l.startswith('ID;Fuente;NO ENCONTRADO'): modo = 'faltan';  continue
        if l.startswith('ID;FRENADO'):              modo = 'frenados'; continue
        if not l.strip():
            continue
        p = l.split(';')
        if modo == 'cambios' and len(p) >= 4:
            try:
                costos[p[0]] = (int(p[3]), p[2])
            except ValueError:
                pass
        elif modo == 'frenados' and len(p) >= 4:
            try:
                frenados.append((p[0], int(p[2]), int(p[3])))
            except ValueError:
                pass
    return costos, frenados


def main():
    simular = '--simular' in sys.argv
    csv = Path(__file__).parent / 'cambios_precios.csv'
    if not csv.exists():
        log('No encuentro cambios_precios.csv. Corré actualizar_precios.py primero.')
        return 1

    costos, frenados = leer_csv(csv)
    log('Reporte: %s' % csv.name)
    log('   %d productos con costo scrapeado' % len(costos))
    log('   %d frenados por el tope del 30%%' % len(frenados))

    filas, sin_costo = [], []
    for fid, viejo, nuevo in frenados:
        if fid in costos:
            filas.append([fid, costos[fid][0]])
        else:
            sin_costo.append(fid)

    if sin_costo:
        log('   %d sin costo en el CSV (se saltean)' % len(sin_costo))
    if not filas:
        log('No hay nada para aplicar.')
        return 0

    suben = sum(1 for _, v, n in frenados if n > v)
    bajan = len(frenados) - suben
    log('\n   %d subirían de precio · %d bajarían' % (suben, bajan))

    if simular:
        log('\n--- SIMULACION: no se toca nada ---')
        for fid, viejo, nuevo in sorted(frenados, key=lambda f: -(f[2] - f[1]) / f[1])[:15]:
            nom = costos.get(fid, (0, '?'))[1]
            log('   %-44s %7d -> %7d' % (nom[:44], viejo, nuevo))
        return 0

    log('\nAplicando %d costos con el freno desactivado (tope=0)...' % len(filas))
    act = igual = sinfila = 0
    for i in range(0, len(filas), LOTE):
        r = post({'action': 'precios_costos', 'rows': filas[i:i + LOTE], 'tope': 0})
        act     += r.get('actualizados', 0)
        igual   += r.get('sinCambio', 0)
        sinfila += r.get('sinFila', 0)
        log('   %d/%d' % (min(i + LOTE, len(filas)), len(filas)))
        time.sleep(0.4)

    log('\n   %d costos aplicados · %d ya estaban igual · %d sin fila' % (act, igual, sinfila))
    log('\nListo. Los precios nuevos se ven en k24hs.com en ~2 minutos.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
