# Corre el actualizador de precios y deja todo registrado en log_precios.txt
# Lo ejecuta solo el Programador de tareas de Windows (ver INSTALAR_ACTUALIZACION_DIARIA.bat)

Set-Location "C:\Users\joe\Claude\Projects\k24"

$inicio = Get-Date
$log    = "log_precios.txt"

Add-Content $log ""
Add-Content $log "==================================================="
Add-Content $log ("CORRIDA: " + $inicio.ToString("dd/MM/yyyy HH:mm:ss"))
Add-Content $log "==================================================="

# Que Python escriba en UTF-8: si no, las tildes y los simbolos llegan al log
# como "categor?as" y ademas pueden hacer explotar un print a mitad de corrida.
$env:PYTHONIOENCODING = "utf-8"
$env:PYTHONUTF8 = "1"

$codigo = 1
try {
    & python actualizar_precios.py *>&1 | Add-Content $log -Encoding UTF8
    $codigo = $LASTEXITCODE
} catch {
    Add-Content $log ("ERROR: " + $_.Exception.Message) -Encoding UTF8
    $codigo = 1
}

$fin = Get-Date
$mins = [math]::Round(($fin - $inicio).TotalMinutes, 1)

if ($codigo -eq 0) {
    Add-Content $log ("OK - termino bien en $mins min") -Encoding UTF8
} else {
    # OJO: antes aca decia "NO se toco ningun precio" y era MENTIRA.
    # Los costos se escriben en lotes de 400 a medida que avanzan, sin
    # transaccion: si falla en el lote 4400, esos 4400 ya quedaron aplicados.
    # Decir lo contrario hacia creer que no habia pasado nada.
    Add-Content $log ("FALLO (codigo $codigo) despues de $mins min") -Encoding UTF8
    Add-Content $log ("   ATENCION: los costos se aplican en lotes mientras corre.") -Encoding UTF8
    Add-Content $log ("   Fijate mas arriba hasta que lote llego: eso YA se aplico.") -Encoding UTF8
    Add-Content $log ("   Volver a correrlo es seguro (reescribe los mismos valores).") -Encoding UTF8
}

# Dejamos el log en un tamanio razonable (ultimas 500 lineas)
try {
    $cont = Get-Content $log -ErrorAction Stop
    if ($cont.Count -gt 500) { $cont | Select-Object -Last 500 | Set-Content $log }
} catch { }
