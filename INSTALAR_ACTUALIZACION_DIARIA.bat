@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
echo ============================================================
echo   INSTALAR LA ACTUALIZACION DIARIA DE PRECIOS
echo ============================================================
echo.
echo   Se va a programar para que corra TODOS LOS DIAS a las 23:00
echo   sin que tengas que hacer nada.
echo.
echo   Si a las 23:00 la PC esta apagada, se ejecuta sola la
echo   proxima vez que la prendas.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
 "$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File \"C:\Users\joe\Claude\Projects\k24\correr_precios.ps1\"';" ^
 "$t = New-ScheduledTaskTrigger -Daily -At 23:00;" ^
 "$s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1);" ^
 "Register-ScheduledTask -TaskName 'K24 - Actualizar precios' -Action $a -Trigger $t -Settings $s -Description 'Actualiza los costos de la planilla de precios K24 desde el Super Mami y la Distribuidora.' -Force | Out-Null;" ^
 "Write-Host '  LISTO: tarea programada correctamente.' -ForegroundColor Green"

if errorlevel 1 (
  echo.
  echo   *** Algo fallo al programar la tarea. Copiame el mensaje. ***
)

echo.
echo ============================================================
echo   Para probarla YA MISMO sin esperar a las 23:
echo   corre PROBAR_ACTUALIZACION.bat
echo.
echo   El resultado de cada corrida queda en log_precios.txt
echo ============================================================
echo.
pause
