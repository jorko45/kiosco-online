@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "fix: restaurar catalog correcto + brand cards Livra/Brio/Cellier/Fresh, Rumipal en gaseosas, Baggio agua saborizada"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
