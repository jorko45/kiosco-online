@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
