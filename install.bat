@echo off
REM MASSO Tool Sync — Fusion 360 Add-in Installer (Windows)

set ADDIN_NAME=MassoToolSync
set SOURCE_DIR=%~dp0%ADDIN_NAME%
set ADDINS_DIR=%APPDATA%\Autodesk\Autodesk Fusion 360\API\AddIns

if not exist "%SOURCE_DIR%" (
    echo Error: %ADDIN_NAME% folder not found.
    echo Make sure you run this script from the repository root.
    pause
    exit /b 1
)

if not exist "%ADDINS_DIR%" (
    echo Error: Fusion 360 AddIns directory not found at:
    echo   %ADDINS_DIR%
    echo.
    echo Make sure Fusion 360 is installed.
    pause
    exit /b 1
)

set DEST=%ADDINS_DIR%\%ADDIN_NAME%

if exist "%DEST%" (
    echo MASSO Tool Sync is already installed.
    set /p confirm="Overwrite? (y/N): "
    if /i not "%confirm%"=="y" (
        echo Cancelled.
        pause
        exit /b 0
    )
    rmdir /s /q "%DEST%"
)

xcopy /E /I /Q "%SOURCE_DIR%" "%DEST%"

echo.
echo MASSO Tool Sync installed successfully!
echo.
echo Next steps:
echo   1. Restart Fusion 360 (or go to Scripts ^& Add-Ins ^> Add-Ins tab)
echo   2. Find 'MassoToolSync' and click Run
echo   3. The MASSO Tool Sync button will appear in Manufacture ^> Milling toolbar
echo.
pause
