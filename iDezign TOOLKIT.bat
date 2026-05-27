@echo off
:: ============================================================================
::  Run-Toolkit-GUI.bat
::  Launches the iDezign Toolkit GUI, self-elevating via UAC on a normal
::  double-click. The script path is quoted so folders with spaces (e.g.
::  "deploy v2") work correctly.
:: ============================================================================
setlocal

set "SCRIPT_DIR=%~dp0"
set "GUI_SCRIPT=%SCRIPT_DIR%iDezign_Toolkit_GUI.ps1"

if not exist "%GUI_SCRIPT%" (
    echo ERROR: iDezign_Toolkit_GUI.ps1 not found in:
    echo   %SCRIPT_DIR%
    echo.
    pause
    exit /b 1
)

:: Already elevated?  net session returns 0 only when running as admin.
net session >nul 2>&1
if %errorlevel%==0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI_SCRIPT%"
) else (
    :: Relaunch elevated. The path is wrapped in escaped quotes so spaces survive.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
        "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','\"%GUI_SCRIPT%\"'"
)

endlocal
