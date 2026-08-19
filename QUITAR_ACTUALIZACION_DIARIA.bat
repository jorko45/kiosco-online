@echo off
echo Quitando la actualizacion automatica de precios...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "Unregister-ScheduledTask -TaskName 'K24 - Actualizar precios' -Confirm:$false; Write-Host '  Listo: ya no se actualiza sola.' -ForegroundColor Yellow"
echo.
echo   (Podes volver a activarla con INSTALAR_ACTUALIZACION_DIARIA.bat)
echo.
pause
