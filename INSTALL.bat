@echo off
title CS2 Recorder setup
if not exist "%~dp0tool\install.ps1" goto notextracted
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tool\install.ps1"
if errorlevel 1 pause
exit /b

:notextracted
echo.
echo  ===============================================================
echo   Extract the zip first!
echo.
echo   1. Close this window.
echo   2. Find the downloaded CS2-Recorder zip file.
echo   3. Right-click it and choose "Extract All...", then "Extract".
echo   4. Open the extracted folder and double-click INSTALL.bat there.
echo  ===============================================================
echo.
pause
