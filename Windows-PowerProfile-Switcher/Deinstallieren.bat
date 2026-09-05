@echo off
rem Deinstallieren.bat - Doppelklick genuegt.
rem Das Fenster bleibt offen, damit Meldungen lesbar bleiben.
cd /d "%~dp0"
echo PowerProfile Switcher wird entfernt ...
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall.ps1"
echo.
echo Fertig. Fenster kann geschlossen werden.
pause
