@echo off
setlocal
cd /d "%~dp0"
title SOOP CONTENT MAKER LAUNCHER

echo [1/3] SOOP server starting...
start "SOOP SERVER" powershell.exe -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0server.ps1"

echo [2/3] Waiting for local server...
set "READY="
for /L %%I in (1,1,15) do (
  powershell.exe -NoLogo -NoProfile -Command "try { $r=Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 'http://127.0.0.1:8770/api/health'; if($r.StatusCode -eq 200){exit 0}else{exit 1} } catch { exit 1 }" >nul 2>&1
  if not errorlevel 1 (
    set "READY=1"
    goto :READY
  )
  timeout.exe /t 1 /nobreak >nul
)

echo.
echo ============================================================
echo Server did not start.
echo Please keep the blue PowerShell window open and show its error message.
echo ============================================================
echo.
pause
exit /b 1

:READY
echo [3/3] Opening SOOP Content Maker...
start "" "http://127.0.0.1:8770/index.html"
exit /b 0
