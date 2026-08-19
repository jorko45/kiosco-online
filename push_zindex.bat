@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "Fix: avisos, favoritos y demas ventanas por encima del panel de usuario (z-index)"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo.
echo.
pause
