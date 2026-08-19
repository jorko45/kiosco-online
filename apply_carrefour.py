import re

DINO_BASE = 'https://statics.dinoonline.com.ar/imagenes/full_600x600_ma/'
CARREFOUR_BASE = 'https://carrefourar.vtexassets.com/arquivos/ids/'

# Load map
url_map = {}
with open('/sessions/amazing-friendly-heisenberg/mnt/k24/carrefour_map.txt') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split('|')
        if len(parts) != 3:
            continue
        code, image_id, filename = parts
        if image_id == 'NULL' or filename == 'NULL':
            continue  # no match found
        new_url = f'{CARREFOUR_BASE}{image_id}/{filename}'
        url_map[code] = new_url

print(f'Loaded {len(url_map)} URL mappings')

# Read index.html
with open('/sessions/amazing-friendly-heisenberg/mnt/k24/index.html', 'r', encoding='utf-8') as f:
    html = f.read()

# Apply replacements
replaced = 0
for code, new_url in url_map.items():
    old_url = f"{DINO_BASE}{code}_f.jpg"
    old_str = f"img:'{old_url}'"
    new_str = f"img:'{new_url}'"
    count = html.count(old_str)
    if count > 0:
        html = html.replace(old_str, new_str)
        replaced += count

print(f'Replaced {replaced} occurrences')

# Check how many Dino URLs remain
remaining = len(re.findall(r'statics\.dinoonline\.com\.ar/imagenes/full_600x600_ma/prod', html))
print(f'Remaining Dino prod URLs: {remaining}')

# Write output
with open('/sessions/amazing-friendly-heisenberg/mnt/k24/index.html', 'w', encoding='utf-8') as f:
    f.write(html)

print('Done.')
