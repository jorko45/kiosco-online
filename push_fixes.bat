@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
git add index.html
git commit -m "fix: logos arcor/brio, AdeS en Baggio, granadinas en botellas, saborizadas por marca, Dos Anclas gondola"
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
