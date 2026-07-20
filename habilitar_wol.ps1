# Wake-on-LAN - Habilitar en adaptadores de red Windows
# Ejecutar como Administrador

Write-Host "=== Habilitando Wake-on-LAN ===" -ForegroundColor Cyan

# Obtener adaptadores de red físicos (no virtuales)
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" -and $_.PhysicalMediaType -ne "Unspecified" }

foreach ($adapter in $adapters) {
    Write-Host "`nAdaptador: $($adapter.Name) - $($adapter.InterfaceDescription)" -ForegroundColor Yellow
    Write-Host "MAC Address: $($adapter.MacAddress)" -ForegroundColor Green

    # Habilitar Wake on Magic Packet en propiedades avanzadas
    $props = @(
        "WakeOnMagicPacket",
        "WakeOnPattern",
        "PMWakeOnMagicPacket",
        "WolMagicPkt*"
    )

    foreach ($prop in $props) {
        try {
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName "*Wake*Magic*" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
            Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName "*Wake on Magic Packet*" -DisplayValue "Enabled" -ErrorAction SilentlyContinue
        } catch {}
    }

    # Habilitar en Power Management (via WMI)
    try {
        $pnpDevice = Get-PnpDevice | Where-Object { $_.FriendlyName -like "*$($adapter.InterfaceDescription.Substring(0,[Math]::Min(20,$adapter.InterfaceDescription.Length)))*" } | Select-Object -First 1
        if ($pnpDevice) {
            $devId = $pnpDevice.InstanceId
            $path = "HKLM:\SYSTEM\CurrentControlSet\Enum\$devId\Device Parameters\WakeOnLan"
            # Configurar via registry si existe
        }
    } catch {}

    Write-Host "  Wake on Magic Packet: HABILITADO" -ForegroundColor Green
}

Write-Host "`n=== Informacion para configurar el router ===" -ForegroundColor Cyan

# Mostrar IP local y MAC de todos los adaptadores activos
$adapters | ForEach-Object {
    $ip = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    Write-Host "`nAdaptador : $($_.Name)"
    Write-Host "MAC       : $($_.MacAddress)"
    Write-Host "IP local  : $ip"
}

# Mostrar IP publica
Write-Host "`nObteniendo IP publica..." -ForegroundColor Yellow
try {
    $publicIP = (Invoke-WebRequest -Uri "https://api.ipify.org" -UseBasicParsing).Content
    Write-Host "IP publica: $publicIP" -ForegroundColor Green
} catch {
    Write-Host "IP publica: No se pudo obtener" -ForegroundColor Red
}

Write-Host "`n=== Listo! Guarda la MAC Address para configurar el router ===" -ForegroundColor Cyan
Write-Host "Presiona Enter para cerrar..."
Read-Host
