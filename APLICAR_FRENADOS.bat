@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo ===========================================================
echo   APLICAR LOS PRECIOS QUE QUEDARON FRENADOS
echo ===========================================================
echo.
echo   El actualizador no aplica un costo si el precio saltaria
echo   mas de 30%%. Este script agarra esos casos del ultimo
echo   cambios_precios.csv y los aplica igual.
echo.
echo   No vuelve a scrapear: usa los costos que ya estan en el
echo   reporte, que son los que revisaste.
echo.
python aplicar_frenados.py
echo.
echo ===========================================================
echo   Los precios nuevos se ven en k24hs.com en ~2 minutos.
echo ===========================================================
echo.
pause
