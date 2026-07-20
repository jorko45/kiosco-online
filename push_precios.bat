@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html api/precios.js apps-script-k24.gs
git commit -m "Precios dinamicos desde planilla Precios K24 (costo/margen/MP) - la web lee y oculta borrados"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
