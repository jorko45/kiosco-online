@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
if exist ".git\HEAD.lock" del ".git\HEAD.lock"
if exist ".git\refs\heads\master.lock" del ".git\refs\heads\master.lock"
git add index.html sync_mami.py
git commit -m "Fiambreria y Lacteos del Mami: 635 productos (lacteos, quesos/fiambres, pizzas) + seccion con tabs y sync"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
