@echo off
:: ============================================================================
::  iDezign TOOLKIT.bat
::  Launches the iDezign Toolkit GUI, self-elevating via UAC on a normal
::  double-click.
::
::  v2.9.1 changes:
::   1. Dropped -WindowStyle Hidden from the elevated relaunch. Some
::      AppLocker default rule sets and Smart App Control silently kill
::      elevated PowerShell launched with -WindowStyle Hidden (it's a known
::      malware-loader pattern). A visible console window adds a half-second
::      flash but launches cleanly under those policies.
::   2. Rewrote control flow to use goto labels instead of "if (...) else (...)"
::      blocks. CMD's IF/ELSE block parser misreads parentheses inside a
::      quoted path - so if this script lives in a folder named, say,
::      "iDezign-Toolkit (7)" (the default name after a second GitHub-zip
::      extract), the old version silently exited. goto-based control flow
::      is immune to that.
:: ============================================================================
setlocal

set "SCRIPT_DIR=%~dp0"
set "GUI_SCRIPT=%SCRIPT_DIR%iDezign_Toolkit_GUI.ps1"

if not exist "%GUI_SCRIPT%" goto :missing

:: Already elevated?  net session returns 0 only when running as admin.
net session >nul 2>&1
if %errorlevel% neq 0 goto :elevate

:run_elevated
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%GUI_SCRIPT%"
goto :end

:elevate
:: Relaunch elevated. Visible window so AppLocker/SmartApp doesn't flag it.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%GUI_SCRIPT%\"'"
goto :end

:missing
echo ERROR: iDezign_Toolkit_GUI.ps1 not found in:
echo   %SCRIPT_DIR%
echo.
pause
goto :end

:end
endlocal
