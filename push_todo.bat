@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"

echo === 1) Guardando TODO lo pendiente ===
git add -A
git commit -m "Legal: boton de arrepentimiento (Res. 424/2020) + verificacion mayor de 18 y bloqueo de alcohol/tabaco"

echo.
echo === 2) Trayendo lo que hay en GitHub ===
git pull --rebase origin main
if errorlevel 1 goto conflicto

echo.
echo === 3) Subiendo ===
git push origin HEAD:main
if errorlevel 1 goto error

echo.
echo ====================================
echo   LISTO. Vercel ya esta deployando.
echo ====================================
goto fin

:conflicto
echo.
echo *** El rebase se trabo. Copiame lo de arriba y lo resolvemos. ***
echo *** Para volver atras sin romper nada: git rebase --abort   ***
goto fin

:error
echo.
echo *** El push fallo. Copiame lo de arriba. ***

:fin
echo.
pause
