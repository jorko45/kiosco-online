@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html apps-script-k24.gs api/precios.js
git commit -m "Legal: boton de arrepentimiento (Res. 424/2020) + verificacion mayor de 18 en registro y bloqueo de alcohol/tabaco"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
