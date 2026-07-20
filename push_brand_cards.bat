@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html img/logos/
git commit -m "feat: brand cards Aquarius/AdeS en aguas, Jugos por Marca (Arcor/Citric/BC/Saldan/Minerva/Favinco), logos /img/logos/"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
