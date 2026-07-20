@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo ===========================================================
echo   ACTUALIZAR SOLO LA DISTRIBUIDORA DEL CENTRO
echo ===========================================================
echo.
echo   El Mami ya se actualizo, asi que este salteo esa parte
echo   y solo trae los precios de la Distribuidora.
echo.
python actualizar_precios.py --solo-distri
echo.
pause
