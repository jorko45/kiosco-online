@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "fix: mover renderSimpleShelf despues de definicion de catalogos (items heladera no se veian)"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
