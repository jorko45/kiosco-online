@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
echo === Preparando cambios ===
git add -u
git add index.html manifest.json sw.js img/*
echo === Guardando (commit) ===
git commit -m "Actualizacion k24hs"
echo === Integrando lo de GitHub ===
git pull --rebase origin main
echo === Subiendo ===
git push origin HEAD:main
echo.
echo Si aparece "CONFLICT" en rojo, avisame antes de tocar nada.
echo Listo. Presiona cualquier tecla para cerrar.
pause
