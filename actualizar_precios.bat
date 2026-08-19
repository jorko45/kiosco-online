@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo ===========================================================
echo   ACTUALIZAR PRECIOS DESDE LAS PAGINAS DE LOS PROVEEDORES
echo ===========================================================
echo.
echo   Trae los precios del Super Mami y de la Distribuidora,
echo   y actualiza SOLO la columna Costo de la planilla.
echo   Tus margenes NO se tocan.
echo.
echo   Puede tardar varios minutos. No cierres esta ventana.
echo.
python actualizar_precios.py
echo.
echo ===========================================================
echo   Si termino bien, revisa cambios_precios.csv
echo   Los precios nuevos se ven en k24hs.com en ~2 minutos.
echo ===========================================================
echo.
pause
