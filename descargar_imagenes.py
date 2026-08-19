"""
K24 - Descargador de imágenes
==============================
Ejecutar una sola vez desde la carpeta del proyecto:
    python descargar_imagenes.py

Descarga todos los logos y fotos de producto a /img/
y actualiza index.html para usar las imágenes locales.
"""

import re, os, time, hashlib, shutil
import urllib.request
from urllib.parse import urlparse

# ── Configuración ─────────────────────────────────────────────
INDEX = os.path.join(os.path.dirname(__file__), 'index.html')
IMG_DIR = os.path.join(os.path.dirname(__file__), 'img')
LOGOS_DIR = os.path.join(IMG_DIR, 'logos')
PROD_DIR  = os.path.join(IMG_DIR, 'productos')

HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
    'Accept': 'image/webp,image/apng,image/*,*/*;q=0.8',
    'Accept-Language': 'es-AR,es;q=0.9',
    'Referer': 'https://kiosco-online.vercel.app/',
}

# ── Crear carpetas ─────────────────────────────────────────────
os.makedirs(LOGOS_DIR, exist_ok=True)
os.makedirs(PROD_DIR,  exist_ok=True)

# ── Leer HTML ─────────────────────────────────────────────────
with open(INDEX, encoding='utf-8') as f:
    content = f.read()

# ── Extraer todas las URLs ────────────────────────────────────
patterns = [
    r"logo:'(https?://[^']+)'",
    r"img:'(https?://[^']+)'",
    r'src=["\']?(https?://[^\s"\'>\)]+)["\']?',
]
urls = set()
for p in patterns:
    for m in re.finditer(p, content):
        u = m.group(1).split('?')[0].split(' ')[0]
        if u.startswith('http'):
            urls.add(m.group(1))  # mantener query string original

print(f"\n📦 {len(urls)} imágenes encontradas en el catálogo\n")

# ── Descargar ─────────────────────────────────────────────────
url_map = {}
ok = fail = skip = 0

for url in sorted(urls):
    # Detectar extensión
    path_part = urlparse(url).path
    ext = os.path.splitext(path_part)[1].lower()
    if ext not in ['.jpg', '.jpeg', '.png', '.webp', '.svg', '.gif']:
        ext = '.jpg'

    # Nombre de archivo: hash corto + nombre legible
    uid = hashlib.md5(url.encode()).hexdigest()[:8]
    base = os.path.basename(path_part).split('?')[0]
    base = re.sub(r'[^\w\-.]', '_', base)[:35]
    if not base or len(base) < 3:
        base = uid
    if not base.endswith(('.jpg','.jpeg','.png','.webp','.svg','.gif')):
        base += ext
    fname = f"{uid}_{base}"

    # ¿Logo o producto?
    pos = content.find(url)
    context = content[max(0, pos-15):pos+5]
    folder = LOGOS_DIR if "logo:'" in context else PROD_DIR
    rel    = 'logos' if folder == LOGOS_DIR else 'productos'

    local = os.path.join(folder, fname)
    rel_url = f'/img/{rel}/{fname}'

    if os.path.exists(local) and os.path.getsize(local) > 500:
        url_map[url] = rel_url
        skip += 1
        continue

    try:
        req = urllib.request.Request(url, headers=HEADERS)
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = resp.read()
        if len(data) < 200:
            raise ValueError(f"Archivo muy pequeño ({len(data)} bytes)")
        with open(local, 'wb') as f:
            f.write(data)
        url_map[url] = rel_url
        ok += 1
        print(f"  ✅ {fname}")
    except Exception as e:
        fail += 1
        print(f"  ❌ {str(e)[:60]}")
        print(f"     {url[:80]}")

    time.sleep(0.2)

print(f"\n📊 Resultado: {ok} descargadas · {skip} ya existían · {fail} fallidas\n")

# ── Actualizar index.html ─────────────────────────────────────
if url_map:
    new_content = content
    for old_url, new_url in url_map.items():
        new_content = new_content.replace(old_url, new_url)

    # Guardar backup
    shutil.copy(INDEX, INDEX + '.backup')

    with open(INDEX, 'w', encoding='utf-8') as f:
        f.write(new_content)

    reemplazos = sum(1 for o in url_map if o in content)
    print(f"✅ index.html actualizado con {len(url_map)} URLs locales")
    print(f"   (backup guardado como index.html.backup)")
else:
    print("⚠️  No se actualizó index.html porque no se descargó nada.")

print("\n🚀 Próximo paso:")
print("   Subí los cambios a GitHub y Vercel los publica automáticamente.")
print("   Las imágenes van a quedar en kiosco-online.vercel.app/img/\n")
