#Requires -Version 5.1
<#
    Watchdog-Tray.ps1

    Prueft, ob das Tray-Icon noch laeuft, und startet es sonst neu. Wird von
    der geplanten Aufgabe "PowerProfileSwitcher-Watchdog" alle 5 Minuten
    aufgerufen.

    Das ist die zweite Sicherung: Der Tray meldet sein Symbol selbst wieder
    an, wenn die Taskleiste es verliert - stirbt dagegen der ganze Prozess
    (Absturz, von Windows beendet), kann er das nicht mehr. Genau dafuer ist
    dieses Skript da.

    Braucht keine Administratorrechte.
#>

$ErrorActionPreference = 'SilentlyContinue'

$StateDir = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$LogFile  = Join-Path $StateDir 'tray.log'

function Write-Log {
    param([string]$Text)
    try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [Watchdog] $Text" | Add-Content -Path $LogFile -Encoding UTF8 } catch { }
}

# Hat der Benutzer den Tray bewusst beendet (z.B. zum Spielen, damit kein
# Hintergrundprozess laeuft), darf der Watchdog ihn NICHT wieder starten.
$PauseFlag = Join-Path $StateDir 'tray-paused.flag'
if (Test-Path $PauseFlag) { exit 0 }

$running = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
           Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' }

if ($running) { exit 0 }

Write-Log 'Tray-Prozess laeuft nicht mehr - starte neu.'
try {
    Start-ScheduledTask -TaskName 'PowerProfileSwitcher-Tray' -ErrorAction Stop
} catch {
    Write-Log "Neustart fehlgeschlagen: $_"
}
