@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "feat: logos y reestructura heladera - Rumipal a gaseosas, Baggio agua saborizada, brand cards Livra/Brio/Cellier/Fresh, fix logos"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
