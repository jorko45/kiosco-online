@echo off
REM ===  EL UNICO BAT QUE NECESITAS PARA SUBIR CAMBIOS  ===
REM Se ejecuta desde una copia en %TEMP% porque el "git pull" puede
REM modificar este mismo archivo mientras corre, y ahi cmd.exe se
REM desalinea y tira errores raros tipo "rigin no se reconoce".
if /i "%~1"=="RUN" goto :run
copy /y "%~f0" "%TEMP%\k24_subir_run.bat" >nul
call "%TEMP%\k24_subir_run.bat" RUN
exit /b

:run
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"

echo === 1) Guardando TODO lo pendiente ===
git add -A
git commit -m "Actualizacion k24hs"

echo.
echo === 2) Trayendo lo de GitHub ===
git pull --rebase origin main

echo.
echo === 3) Subiendo ===
git push origin HEAD:main

echo.
echo Si arriba ves algo como "..  HEAD -^> main", quedo subido.
echo Vercel tarda 1-2 minutos en publicarlo.
echo Si aparece "CONFLICT" en rojo, avisame antes de tocar nada.
echo.
pause
