@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo === Descargando fotos de cigarrillos ===
py -3 bajar_fotos_cigarrillos.py 2>nul || python bajar_fotos_cigarrillos.py
if errorlevel 1 (
  echo ERROR: revisa que Python este instalado
  pause
  exit /b 1
)
echo.
echo === Subiendo cambios ===
if exist ".git\index.lock" del ".git\index.lock"
git add index.html img/cigarrillos
git commit -m "feat: fotos de cigarrillos descargadas en local (sin hotlink a pedix)"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
