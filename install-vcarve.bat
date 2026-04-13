@echo off
REM Double-click launcher for install.ps1
REM Bypasses execution policy so the user doesn't need to configure PowerShell.
REM Explicitly pass -GadgetSource so the script finds the gadget folder
REM regardless of how PowerShell resolves $PSScriptRoot.

setlocal
set "SCRIPT_DIR=%~dp0"
REM Strip trailing backslash for a cleaner path
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

echo.
echo Installing MASSO Tool Sync for VCarve Pro...
echo Source folder: %SCRIPT_DIR%
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\install.ps1" -GadgetSource "%SCRIPT_DIR%\MassoToolSync_VCarve"

echo.
pause
