@echo off
cd /d "%~dp0"
echo DEBUG v1.0 - PowerShell bleibt sichtbar.
echo.
powershell.exe -NoProfile -NoExit -ExecutionPolicy Bypass -File "%~dp0src\Dell7090FanControl.ps1"
