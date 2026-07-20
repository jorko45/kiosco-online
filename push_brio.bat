@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add img/logos/brio.png
git add img/logos/BRIO.png
git commit -m "feat: logo Brio"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
