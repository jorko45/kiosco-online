@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "Gate +18: bloqueo exacto por ID de seccion (Quilmes, Marlboro, Sernova y demas marcas) + mas marcas en el filtro por nombre"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo.
echo.
pause
