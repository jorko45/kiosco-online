@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo ============================================================
echo   PROBANDO LA ACTUALIZACION (la misma que corre a las 23)
echo ============================================================
echo.
echo   Puede tardar varios minutos. No cierres esta ventana.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "Start-ScheduledTask -TaskName 'K24 - Actualizar precios'; Write-Host '  Tarea disparada. Esperando a que termine...' -ForegroundColor Cyan;" ^
 "do { Start-Sleep -Seconds 5; $e = (Get-ScheduledTask -TaskName 'K24 - Actualizar precios').State } while ($e -eq 'Running');" ^
 "Write-Host '  Termino.' -ForegroundColor Green"

echo.
echo ============================================================
echo   RESULTADO (ultimas lineas del log):
echo ============================================================
powershell -NoProfile -Command "Get-Content log_precios.txt -Tail 18"
echo.
echo   El log completo esta en log_precios.txt
echo.
pause
