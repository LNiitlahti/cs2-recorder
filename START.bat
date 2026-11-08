@echo off
title CS2 Recorder
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0tool\wizard.ps1"
if errorlevel 1 (
  echo.
  echo Something went wrong. The log is in the "data" folder: wizard.log
  pause
)
