@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo ============================================================
echo   SIMULACION - NO CAMBIA NINGUN PRECIO
echo ============================================================
echo.
echo   Te muestra que precios cambiarian si actualizaras ahora,
echo   pero no toca absolutamente nada.
echo.
echo   Puede tardar varios minutos.
echo.
python actualizar_precios.py --simular
echo.
echo ============================================================
echo   Si estas de acuerdo con los cambios, corre
echo   actualizar_precios.bat para aplicarlos de verdad.
echo ============================================================
echo.
pause
