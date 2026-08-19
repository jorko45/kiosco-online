@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
if exist ".git\HEAD.lock" del ".git\HEAD.lock"
git add .github/workflows/sync-mami.yml
git commit -m "Auto-sync de precios del Mami (GitHub Action programado)"
git push origin HEAD:main
echo.
echo Listo. Ahora activa los permisos en GitHub (te lo explica el asistente).
echo Presiona una tecla para cerrar.
pause
