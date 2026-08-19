@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"

echo === 1) Sacando la basura del repo (los archivos NO se borran del disco) ===
git rm -r --cached --quiet ".~lock.lista_precios_completa.xlsx#" 2>nul
git rm -r --cached --quiet ".~lock.lista_precios_mami.xlsx#" 2>nul
git rm -r --cached --quiet ".~lock.lista_precios_venta.xlsx#" 2>nul
git rm -r --cached --quiet ".~lock.lista_precios_verificacion.xlsx#" 2>nul
git rm -r --cached --quiet ".~lock.precios_editable_google.xlsx#" 2>nul
git rm -r --cached --quiet "__pycache__" 2>nul
git rm --cached --quiet "index.html.backup" 2>nul
git rm --cached --quiet "apps-script-actual.txt" 2>nul
git rm --cached --quiet "dino_products.json" 2>nul
git rm --cached --quiet "_precios_master.json" 2>nul
git rm --cached --quiet "portada.png" 2>nul
git rm --cached --quiet "Kiosco Interactivo.png" 2>nul
git rm --cached --quiet "Gemini_Generated_Image_wabnfzwabnfzwabn.png" 2>nul
git rm --cached --quiet "image_17909ca8 (2).png" 2>nul
for %%F in (*.xlsx) do git rm --cached --quiet "%%F" 2>nul

echo === 2) Commit de limpieza + .gitignore ===
git add .gitignore
git commit -m "Limpieza: sacar del repo planillas, backups, cache y locks + .gitignore"

echo === 3) Sincronizar y subir ===
git pull --rebase origin main
git push origin HEAD:main

echo.
echo Si arriba dice algo con "main -^> main", quedo subido.
echo.
pause
