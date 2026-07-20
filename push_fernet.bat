@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "Repetidos entre tarjeta de marca y ficha suelta (Fernet Branca, Pepsi, Sprite): queda la tarjeta con el precio mas bajo"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo.
echo.
pause
