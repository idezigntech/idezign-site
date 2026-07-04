@echo off
:: ============================================================================
::  iDezign TOOLKIT.bat
::  Launches the iDezign Toolkit GUI, self-elevating via UAC on a normal
::  double-click.
::
::  v2.9.2-bat changes (window suppression - pairs with GUI v2.9.3):
::   1. Self-minimize: on first launch the bat relaunches ITSELF minimized
::      and exits, so the console the user sees is a taskbar blip instead
::      of a popup window over their screen.
::   2. The elevated PowerShell spawns with -WindowStyle Minimized. NOTE:
::      minimized, NOT hidden - AppLocker default rules and Smart App
::      Control silently kill elevated PowerShell launched with
::      -WindowStyle Hidden (known malware-loader pattern). Minimized is
::      a normal visible launch. The GUI script then hides its own console
::      entirely once it's up (ShowWindow self-hide, GUI v2.9.3).
::
::  v2.9.1 changes (retained):
::   1. Dropped -WindowStyle Hidden from the elevated relaunch (see above).
::   2. goto-label control flow instead of "if (...) else (...)" blocks.
::      CMD's IF/ELSE block parser misreads parentheses inside a quoted
::      path - e.g. a folder named "iDezign-Toolkit (7)" after a second
::      GitHub-zip extract silently exited. goto-based flow is immune.
:: ============================================================================
setlocal

:: --- Self-minimize: relaunch minimized once, then exit this instance -------
if defined IDZ_MINIMIZED goto :main
set "IDZ_MINIMIZED=1"
start "iDezign Toolkit" /min cmd /c ""%~dpnx0""
goto :end

:main
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
:: Relaunch elevated, minimized (NOT hidden - see header). The GUI hides
:: its own console once loaded, so the minimized window is a taskbar blip.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell.exe -Verb RunAs -WindowStyle Minimized -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','\"%GUI_SCRIPT%\"'"
goto :end

:missing
echo ERROR: iDezign_Toolkit_GUI.ps1 not found in:
echo   %SCRIPT_DIR%
echo.
pause
goto :end

:end
endlocal
