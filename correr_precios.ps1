# Corre el actualizador de precios y deja todo registrado en log_precios.txt
# Lo ejecuta solo el Programador de tareas de Windows (ver INSTALAR_ACTUALIZACION_DIARIA.bat)

Set-Location "C:\Users\joe\Claude\Projects\k24"

$inicio = Get-Date
$log    = "log_precios.txt"

Add-Content $log ""
Add-Content $log "==================================================="
Add-Content $log ("CORRIDA: " + $inicio.ToString("dd/MM/yyyy HH:mm:ss"))
Add-Content $log "==================================================="

$codigo = 1
try {
    & python actualizar_precios.py *>&1 | Add-Content $log
    $codigo = $LASTEXITCODE
} catch {
    Add-Content $log ("ERROR: " + $_.Exception.Message)
    $codigo = 1
}

$fin = Get-Date
$mins = [math]::Round(($fin - $inicio).TotalMinutes, 1)

if ($codigo -eq 0) {
    Add-Content $log ("OK - termino bien en $mins min")
} else {
    Add-Content $log ("FALLO (codigo $codigo) despues de $mins min - NO se toco ningun precio")
}

# Dejamos el log en un tamanio razonable (ultimas 500 lineas)
try {
    $cont = Get-Content $log -ErrorAction Stop
    if ($cont.Count -gt 500) { $cont | Select-Object -Last 500 | Set-Content $log }
} catch { }
