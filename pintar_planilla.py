# -*- coding: utf-8 -*-
"""
pintar_planilla.py — Pinta la planilla de precios segun lo que el actualizador
le hace REALMENTE a cada fila.

  Naranja  = ancla. La congelaste a proposito: se informa el costo, no se toca
             el precio. La lista vive en ANCLAS, dentro de actualizar_precios.py.
  Gris     = nadie publica su precio (promos, cigarrillos, combos). El
             actualizador no la mira nunca.
  Sin color = se actualiza sola todos los dias.

Por que existe: antes se pintaba de naranja toda fila con "__" en el id, dando
por hecho que las tarjetas de marca eran manuales. Al restaurar mapa_marcas.json
216 de ellas pasaron a actualizarse solas y el color quedo mintiendo.

No cambia ningun precio. Solo colores.
"""
import json
import sys

import actualizar_precios as ap


def main():
    ap.MAPA_MARCAS = ap.cargar_mapa_marcas()
    ap.log('Bajando la lista de productos de la planilla...')
    filas = json.loads(ap.fetch(ap.API_PRECIOS, timeout=90))['items']
    ap.log('   %d filas' % len(filas))

    anclas, sin_proveedor, automaticas = [], [], 0
    for f in filas:
        fid = str(f[0])
        if fid in ap.ANCLAS:
            anclas.append(fid)
        elif ap.id_mami(fid) is not None or fid.startswith('d-'):
            automaticas += 1
        else:
            sin_proveedor.append(fid)

    ap.log('\n   %d anclas congeladas' % len(anclas))
    ap.log('   %d sin proveedor' % len(sin_proveedor))
    ap.log('   %d se actualizan solas' % automaticas)

    if '--simular' in sys.argv:
        ap.log('\n(simulacion: no se pinto nada)')
        return

    ap.log('\nPintando...')
    r = ap.post({'action': 'precios_pintar',
                 'anclas': anclas,
                 'sinProveedor': sin_proveedor})
    if not r.get('ok'):
        err = str(r.get('error', r))
        # El script viejo no conoce 'precios_pintar' y se cae al final de doPost,
        # que intenta abrir una planilla que ya no existe. El mensaje habla de
        # una planilla, pero el problema es que falta publicar la version nueva.
        vieja = r.get('accionDesconocida') or 'Illegal spreadsheet' in err
        ap.log('   No se pudo pintar: %s' % err)
        if vieja:
            ap.log('')
            ap.log('   >> El Apps Script publicado es el VIEJO: no conoce esta accion.')
            ap.log('      1) Abri apps-script-k24.gs y copia TODO')
            ap.log('      2) Pegalo encima en el editor de Apps Script')
            ap.log('      3) Implementar > Administrar implementaciones > editar la que YA existe')
            ap.log('         (crear una nueva cambia la URL y rompe el sitio)')
            ap.log('      4) Volve a correr este .bat')
        sys.exit(1)
    ap.log('   naranja (anclas): %s' % r.get('anclas'))
    ap.log('   gris (sin proveedor): %s' % r.get('sinProveedor'))
    ap.log('   sin color (automaticas): %s' % r.get('automaticas'))
    ap.log('\nListo. Abri la planilla y mira los colores.')


if __name__ == '__main__':
    try:
        main()
    except Exception as e:
        ap.log('\nERROR: %s' % e)
        sys.exit(1)
