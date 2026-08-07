@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo ===========================================================
echo   PINTAR LA PLANILLA DE PRECIOS
echo ===========================================================
echo.
echo   NO cambia ningun precio. Solo colores.
echo.
echo   Naranja   = ancla: la congelaste, no se toca sola
echo   Gris      = sin proveedor: nadie publica su precio
echo   Sin color = se actualiza sola todos los dias
echo.
echo   OJO: antes de correr esto por primera vez hay que pegar
echo   la version nueva de apps-script-k24.gs en el editor de
echo   Apps Script y volver a publicarla.
echo.
python pintar_planilla.py
echo.
pause
