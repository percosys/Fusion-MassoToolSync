@echo off
REM Double-click launcher for install.ps1
REM Bypasses execution policy so the user doesn't need to configure PowerShell.

setlocal
set "SCRIPT_DIR=%~dp0"

echo.
echo Installing MASSO Tool Sync for VCarve Pro...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1"

echo.
pause
