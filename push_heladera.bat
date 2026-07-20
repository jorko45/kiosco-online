@echo off
cd /d "C:\Users\joe\Claude\Projects\k24"
if exist ".git\index.lock" del /f ".git\index.lock"
git add index.html
git commit -m "feat: jugos/saborizadas/espumantes en heladera - 3 nuevos estantes frios"
git push origin HEAD:main
