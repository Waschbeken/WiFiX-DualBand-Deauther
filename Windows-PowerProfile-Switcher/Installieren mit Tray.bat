@echo off
rem Installiert zusaetzlich das dauerhaft laufende Tray-Icon.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1" -WithTray
echo.
pause
