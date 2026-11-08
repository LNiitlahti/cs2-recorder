@echo off
title CS2 Recorder
if not exist "%~dp0tool\wizard.ps1" (
  echo.
  echo  Extract the zip first: right-click the zip, choose "Extract All...",
  echo  then run INSTALL.bat from the extracted folder.
  echo.
  pause
  exit /b
)
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tool\wizard.ps1"
if errorlevel 1 (
  echo.
  echo Something went wrong. The log is in the "data" folder: wizard.log
  pause
)
