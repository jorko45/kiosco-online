@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "Botellas: la cava/toneles/gondola se rearman con los precios de la planilla (sin duplicar marcas)"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo.
echo.
pause
