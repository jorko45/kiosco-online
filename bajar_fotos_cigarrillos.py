# -*- coding: utf-8 -*-
"""
bajar_fotos_cigarrillos.py — Descarga las fotos de cigarrillos hotlinkeadas
(cdn.pedix.app) a img/cigarrillos/ y actualiza index.html para usarlas en local.
Idempotente: si ya están bajadas, no hace nada.
"""
import re
import ssl
import urllib.request
from pathlib import Path

_SSL_CTX = ssl.create_default_context()
_SSL_CTX.check_hostname = False
_SSL_CTX.verify_mode = ssl.CERT_NONE
HEADERS = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/126.0'}

BASE_DIR = Path(__file__).parent
DEST = BASE_DIR / 'img' / 'cigarrillos'
DEST.mkdir(parents=True, exist_ok=True)

idx = BASE_DIR / 'index.html'
src = idx.read_text(encoding='utf-8')

urls = sorted(set(re.findall(r"https://cdn\.pedix\.app/[^'\"]+", src)))
print(f'{len(urls)} fotos de Pedix encontradas en index.html')

ok, fallos = 0, 0
for url in urls:
    fid = url.split('/products/')[1].split('?')[0]          # ej: F0n2r6mw...png
    fname = re.sub(r'[^A-Za-z0-9_.-]', '', fid)
    local = DEST / fname
    if not local.exists():
        try:
            req = urllib.request.Request(url, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=45, context=_SSL_CTX) as r:
                data = r.read()
            if len(data) < 500:
                raise ValueError('archivo demasiado chico')
            local.write_bytes(data)
            print(f'  ✔ {fname} ({len(data)//1024} KB)')
        except Exception as e:
            print(f'  ✖ {fname}: {e}')
            fallos += 1
            continue
    src = src.replace(url, f'/img/cigarrillos/{fname}')
    ok += 1

idx.write_text(src, encoding='utf-8')
print(f'\n{ok} fotos locales, {fallos} fallidas. index.html actualizado.')
