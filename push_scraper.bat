@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add actualizar_precios.py actualizar_precios.bat actualizar_solo_distri.bat apps-script-k24.gs CONTEXTO_K24.md
git commit -m "Actualizador de precios desde Mami y Distribuidora (solo columna Costo, margenes intactos) + salvaguarda"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo.
echo.
pause
