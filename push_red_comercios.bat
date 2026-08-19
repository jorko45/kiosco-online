@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html apps-script-k24.gs
git commit -m "Delivery inmediato + seccion Sumate a la red de comercios con formulario"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo.
echo.
pause
