@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo === Sincronizando con SuperMami ===
py -3 sync_mami.py 2>nul || python sync_mami.py
if errorlevel 1 (
  echo.
  echo ERROR: revisa que Python este instalado
  pause
  exit /b 1
)
echo.
echo === Subiendo cambios ===
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "sync: precios y golosinas desde SuperMami"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
