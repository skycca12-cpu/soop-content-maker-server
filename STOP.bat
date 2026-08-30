@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Get-NetTCPConnection -LocalPort 8770 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }"
exit
