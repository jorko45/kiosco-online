@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del ".git\index.lock"
if exist ".git\HEAD.lock" del ".git\HEAD.lock"
if exist ".git\refs\heads\master.lock" del ".git\refs\heads\master.lock"
git add index.html manifest.json sw.js img/logo-k24hs.png img/kiosco-hero.jpg img/icon-192.png img/icon-512.png img/icon-maskable-512.png img/apple-touch-icon.png
git commit -m "Rediseno: logo k24hs (reloj-puestito) en header, sello circular como icono PWA, nueva portada + hotspots reubicados"
git pull --rebase origin main
git push origin HEAD:main
echo.
echo Listo. Presiona cualquier tecla para cerrar.
pause
