@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"

:: Agregar solo los logos correctos (no BRIO.png ni arcor_new.jpeg)
git add img/logos/rumipal.png
git add img/logos/aquarius.png
git add img/logos/ades.png
git add img/logos/arcor.png
git add img/logos/bc.png
git add img/logos/cellier.png
git add img/logos/citric.png
git add img/logos/favinco.png
git add img/logos/fresh.png
git add img/logos/levite.png
git add img/logos/livra.png
git add img/logos/minerva.png
git add img/logos/saldan.jpg
git add img/logos/brio.png

git commit -m "feat: logos brand cards - rumipal/aquarius/ades/arcor/citric/bc/saldan/minerva/favinco/levite/brio/cellier/fresh/livra"
git push origin HEAD:main

echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
