@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "Buzon: fechas legibles (19/07/2026 - 11:05) en vez del formato largo"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo.
echo.
pause
