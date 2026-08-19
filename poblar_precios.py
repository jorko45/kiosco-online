# -*- coding: utf-8 -*-
"""
poblar_precios.py — Crea/llena la planilla "Precios K24" en el Drive de
k24hsonline@gmail.com con TODOS los productos (id, sección, categoría,
producto, costo, margen, MP, precio venta).

Se corre UNA vez (o cuando quieras regenerar la planilla desde cero).
Lee el archivo _precios_master.json que está en esta misma carpeta.
Solo usa la librería estándar de Python.
"""
import json, ssl, urllib.request, time
from pathlib import Path

EXEC = 'https://script.google.com/macros/s/AKfycbz48Hs8pcO-ewcmnxaHrS-eBrcVk-llMdaCxjNyCXOdP99SahO7X84w-97bs_JvuzOL/exec'
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
LOTE = 400

def post(payload):
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(EXEC, data=data, headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=120, context=CTX) as r:
        return json.loads(r.read().decode('utf-8', errors='replace'))

def main():
    rows = json.loads((Path(__file__).parent / '_precios_master.json').read_text(encoding='utf-8'))
    print(f'{len(rows)} productos a cargar...')
    print('Vaciando planilla...'); print(' ', post({'action': 'precios_reset'}))
    total = 0
    for i in range(0, len(rows), LOTE):
        lote = rows[i:i+LOTE]
        res = post({'action': 'precios_append', 'rows': lote})
        total = res.get('total', total)
        print(f'  {i+len(lote)}/{len(rows)}  (planilla: {total})')
        time.sleep(0.5)
    print('\nLISTO. La planilla "Precios K24" está en el Drive de k24hsonline@gmail.com')
    print('Editá costo/margen/MP o borrá filas y se refleja en la web en ~2 min.')

if __name__ == '__main__':
    main()
