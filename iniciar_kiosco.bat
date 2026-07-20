@echo off
title K24 Kiosco - Servidor Local
echo.
echo  ██████ K24 Kiosco Online ██████
echo  Iniciando servidor local...
echo  Para salir, cerra esta ventana.
echo.
cd /d "%~dp0"

:: Esperar 1 segundo y abrir el navegador
start "" timeout /t 1 /nobreak >nul
start "" "http://localhost:8080"

:: Intentar con Python 3
python -m http.server 8080 2>nul
if %errorlevel% neq 0 (
    :: Intentar con Python (algunas instalaciones usan "python" vs "py")
    py -m http.server 8080 2>nul
    if %errorlevel% neq 0 (
        echo.
        echo  ERROR: No se encontro Python.
        echo  Instala Python desde https://python.org
        echo  (marcando "Add to PATH" durante la instalacion)
        echo.
        pause
    )
)
