@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
echo === Guardando cambios sueltos (sync_mami.py, etc) ===
git stash
echo === Integrando lo que hay en GitHub ===
git pull --rebase origin main
echo === Subiendo tu rama actual a main ===
git push origin HEAD:main
echo === Restaurando cambios sueltos ===
git stash pop
echo.
echo Si arriba dice "CONFLICT" o algo en rojo, avisame antes de tocar nada.
echo Listo. Presiona cualquier tecla para cerrar.
pause
