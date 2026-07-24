# -*- coding: utf-8 -*-
"""
probar_codigo_mami.py — Sonda: revisa si las paginas de producto del Super Mami
muestran el codigo de barras (EAN). Si lo muestran, podemos capturarlo directo
para todo el catalogo, sin emparejar por nombre (que es lo que falla).

No cambia nada. Solo mira y reporta.
"""
import re, ssl, urllib.request

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
HEADERS = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                         '(KHTML, like Gecko) Chrome/126.0 Safari/537.36'}
BASE = 'https://www.dinoonline.com.ar'

# Unos productos conocidos (id de dinoonline -> que es), para probar
PRUEBAS = [
    ('3080006', 'Coca Cola 500'),
    ('3080015', 'Coca Cola 1.5L'),
    ('3070001', 'Fernet Branca 750'),
    ('3100966', 'Quilmes 473 lata'),
    ('2540971', 'Fideos Matarazzo'),
]


def fetch(url):
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=45, context=CTX) as r:
        return r.read().decode('utf-8', errors='replace')


def buscar_ean(html):
    """Busca el EAN cerca de palabras clave tipo gtin/barcode/codigo."""
    hallazgos = set()
    for pat in [
        r'"gtin\d*"\s*:\s*"?(\d{8,14})',
        r'"barcode"\s*:\s*"?(\d{8,14})',
        r'(?:ean|gtin|barcode|codigo\s*de\s*barras|c\.?\s*barras)[^0-9]{0,20}(\d{13})',
        r'\b(779\d{10})\b',   # EAN argentino tipico empieza con 779
    ]:
        for m in re.finditer(pat, html, re.I):
            hallazgos.add(m.group(1))
    return hallazgos


def main():
    print('Probando si el Mami muestra el codigo de barras...\n')
    urls = [
        BASE + '/super/producto/_/A-%s',
        BASE + '/super/producto/x/_/A-%s',
    ]
    encontrados = 0
    for pid, nombre in PRUEBAS:
        hallado = None
        for tpl in urls:
            try:
                html = fetch(tpl % pid)
            except Exception:
                continue
            eans = buscar_ean(html)
            if eans:
                hallado = sorted(eans)[:3]
                break
        if hallado:
            encontrados += 1
            print('  OK  %-22s -> codigo(s): %s' % (nombre, ', '.join(hallado)))
        else:
            print('  --  %-22s -> no encontre codigo en la pagina' % nombre)

    print()
    if encontrados >= 2:
        print('==> BUENA NOTICIA: el Mami muestra el codigo de barras.')
        print('    Con esto podemos capturarlo para TODO el catalogo, exacto y sin adivinar.')
        print('    Avisale a Claude y lo dejamos automatico.')
    else:
        print('==> El Mami NO muestra el codigo (o cambio de formato).')
        print('    Pasale a Claude las lineas de arriba y vemos el plan B.')


if __name__ == '__main__':
    main()
