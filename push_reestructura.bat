@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "feat: reestructura heladera/botellas/gondola - cervezas/aguas/gaseosas a heladera, vinos/licores a botellas, jugos polvo a gondola, sin duplicados, ssc-card mas grande"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
