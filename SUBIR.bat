@echo off
REM ===  EL UNICO BAT QUE NECESITAS PARA SUBIR CAMBIOS  ===
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"

echo === 1) Guardando TODO lo pendiente ===
git add -A
git commit -m "Actualizacion k24hs"

echo.
echo === 2) Trayendo lo de GitHub ===
git pull --rebase origin main

echo.
echo === 3) Subiendo ===
git push origin HEAD:main

echo.
echo Si arriba ves algo como "..  HEAD -^> main", quedo subido.
echo Vercel tarda 1-2 minutos en publicarlo.
echo Si aparece "CONFLICT" en rojo, avisame antes de tocar nada.
echo.
pause
