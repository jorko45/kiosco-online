@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
echo Empujando un commit vacio para despertar a Vercel...
git commit --allow-empty -m "deploy: destrabar Vercel"
git push origin HEAD:main
echo.
echo Listo. Dale 1-2 minutos y avisame.
echo.
pause
