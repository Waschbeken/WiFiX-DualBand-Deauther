@echo off
rem Installieren.bat - Doppelklick genuegt.
rem Fuer das Tray-Icon stattdessen "Installieren mit Tray.bat" nehmen.
cd /d "%~dp0"
echo PowerProfile Switcher wird eingerichtet ...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
echo.
pause
