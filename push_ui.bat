@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
if exist ".git\HEAD.lock" del ".git\HEAD.lock"
if exist ".git\refs\heads\master.lock" del ".git\refs\heads\master.lock"
git add index.html api/estado.js api/precios.js
git commit -m "Duplicados: restaurar heladera y quitar los 51 items crudos del Mami"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
