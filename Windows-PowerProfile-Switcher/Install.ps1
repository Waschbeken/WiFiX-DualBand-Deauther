#Requires -Version 5.1
<#
    Install.ps1

    Richtet PowerProfile Switcher ein:
      1. Kopiert die Skripte nach %LOCALAPPDATA%\PowerProfileSwitcher
      2. Legt 3 geplante Aufgaben an (Gaming/Balanced/Travel), die mit
         erhoehten Rechten laufen, damit powercfg alles aendern darf, ohne
         dass bei jedem Klick ein UAC-Fenster erscheint.
      3. Legt eine 4. geplante Aufgabe an, die das Tray-Icon bei jeder
         Anmeldung startet.
      4. Erstellt Desktop-Verknuepfungen zum sofortigen Umschalten.

    Muss einmalig als Administrator ausgefuehrt werden (elevatiert sich
    bei Bedarf automatisch selbst).
#>

param(
    # Richtet zusaetzlich das dauerhaft laufende Tray-Icon samt Ueberwachung
    # ein. Standardmaessig AUS: ein dauerhafter versteckter Prozess stoert
    # Anti-Cheat-Systeme. Ohne Tray gibt es das Programmfenster und die
    # Verknuepfungen - dabei laeuft nur etwas, wenn du es benutzt.
    # (Watt-Anzeige, Protokoll, Standby-Auswertung und automatisches
    # Umschalten setzen das Tray-Icon voraus.)
    [switch]$WithTray,

    # Nur noch aus Kompatibilitaet - ohne Wirkung, da der Tray ohnehin
    # standardmaessig nicht eingerichtet wird.
    [switch]$NoTray
)

$installTray = $WithTray -and -not $NoTray

$ErrorActionPreference = 'Stop'

function Write-Info($Text) { Write-Host "[Install] $Text" -ForegroundColor Cyan }

# --- Selbst-Elevation -------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Starte erneut mit Administratorrechten ...'
    $scriptPath = $MyInvocation.MyCommand.Path
    $installArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
    if ($WithTray) { $installArgs += '-WithTray' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $installArgs
    exit
}

$SourceDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$UserId     = "$env:USERDOMAIN\$env:USERNAME"

Write-Info "Installiere nach $InstallDir ..."
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

foreach ($file in 'Set-PowerProfile.ps1', 'Start-Tray.ps1', 'PowerMetrics.ps1', 'Profiles.ps1',
                  'Test-PowerProfile.ps1', 'New-PowerReport.ps1', 'Update-PowerProfile.ps1',
                  'Test-PowerPerformance.ps1', 'Show-PowerSettings.ps1', 'PowerBench.ps1',
                  'Invoke-PowerCalibration.ps1', 'Start-PowerSetup.ps1', 'Watchdog-Tray.ps1',
                  'PowerDisplay.ps1', 'Reset-PowerProfile.ps1', 'Show-PowerStatus.ps1',
                  'Backup-PowerConfig.ps1', 'Set-PowerBackground.ps1', 'Show-PowerWindow.ps1',
                  'Uninstall.ps1') {
    Copy-Item -Path (Join-Path $SourceDir $file) -Destination (Join-Path $InstallDir $file) -Force
}

# Einmalig die urspruenglichen Energieeinstellungen sichern, bevor die App
# ueberhaupt etwas anfasst. Wiederherstellen spaeter mit powercfg /import.
$backupFile = Join-Path $InstallDir 'backup-original-scheme.pow'
if (-not (Test-Path $backupFile)) {
    try {
        powercfg /export "$backupFile" SCHEME_CURRENT 2>&1 | Out-Null
        if (Test-Path $backupFile) {
            Write-Info "Urspruengliche Energieeinstellungen gesichert: $backupFile"
        }
    } catch {
        Write-Warning 'Die urspruenglichen Energieeinstellungen konnten nicht gesichert werden.'
    }
}

$SetProfileScript = Join-Path $InstallDir 'Set-PowerProfile.ps1'
$TrayScript       = Join-Path $InstallDir 'Start-Tray.ps1'

# Profil-Definitionen laden, damit Aufgaben und Verknuepfungen automatisch
# zu den in Profiles.ps1 definierten Profilen passen (auch neu hinzugefuegten).
. (Join-Path $SourceDir 'Profiles.ps1')

# Gemeinsame Aufgaben-Einstellungen fuer alle geplanten Aufgaben:
#  - kein 72-Stunden-Zeitlimit (Standard!) - sonst wird v.a. das dauerhaft
#    laufende Tray-Icon nach 3 Tagen automatisch vom Taskplaner beendet
#  - laeuft/stoppt NICHT beim Wechsel auf Akkubetrieb (Standard stoppt
#    laufende Aufgaben, sobald das Netzteil getrennt wird - genau der
#    Moment, in dem man auf "Unterwegs" umschaltet!)
#  - startet bei Absturz bis zu 3x automatisch neu
$taskSettings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1)

# --- Geplante Aufgaben je Profil (erhoehte Rechte, kein UAC-Prompt beim Ausloesen) ---
foreach ($p in $ProfileDefinitions.Keys) {
    $taskName = "PowerProfileSwitcher-$p"
    Write-Info "Richte geplante Aufgabe '$taskName' ein ..."

    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SetProfileScript`" -Mode $p"

    $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $taskSettings `
        -Description "PowerProfile Switcher: Profil '$p' aktivieren" | Out-Null
}

# --- Zusatzaufgabe fuer das automatische Umschalten ---------------------
# Gleiches Profil, aber ohne GPU-Umschaltung: beim Ausstecken des Netzteils
# soll nicht jedes Mal die Neustart-Abfrage der GPU-Deaktivierung kommen.
$noGpuTaskName = 'PowerProfileSwitcher-Travel-NoGpu'
Write-Info "Richte geplante Aufgabe '$noGpuTaskName' ein ..."
Unregister-ScheduledTask -TaskName $noGpuTaskName -Confirm:$false -ErrorAction SilentlyContinue

$noGpuAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SetProfileScript`" -Mode Travel -SkipGpu"
$noGpuPrincipal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Highest

Register-ScheduledTask -TaskName $noGpuTaskName -Action $noGpuAction -Principal $noGpuPrincipal `
    -Settings $taskSettings -Description 'PowerProfile Switcher: Unterwegs ohne GPU-Umschaltung (automatischer Wechsel)' | Out-Null

# --- Tray-Icon und Ueberwachung (entfallen bei -NoTray) ------------------
$trayTaskName = 'PowerProfileSwitcher-Tray'
if (-not $installTray) {
    Write-Info 'Installation ohne Hintergrunddienst: kein Tray-Icon, keine Ueberwachung.'
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($task in $trayTaskName, 'PowerProfileSwitcher-Watchdog') {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    }
}

if ($installTray) {
Write-Info "Richte Autostart fuer das Tray-Icon ein ..."

# Falls bereits eine alte Tray-Instanz laeuft (z.B. bei erneuter
# Installation/Update), zuerst beenden, damit nicht zwei Icons entstehen.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Unregister-ScheduledTask -TaskName $trayTaskName -Confirm:$false -ErrorAction SilentlyContinue

$trayAction    = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$TrayScript`""
$trayTrigger   = New-ScheduledTaskTrigger -AtLogOn -User $UserId
$trayPrincipal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $trayTaskName -Action $trayAction -Trigger $trayTrigger `
    -Principal $trayPrincipal -Settings $taskSettings `
    -Description 'PowerProfile Switcher: Tray-Icon bei Anmeldung starten' | Out-Null
}

# --- Watchdog: startet das Tray-Icon neu, falls der Prozess stirbt ------
if ($installTray) {
$watchdogTaskName = 'PowerProfileSwitcher-Watchdog'
Write-Info "Richte Ueberwachung '$watchdogTaskName' ein ..."
Unregister-ScheduledTask -TaskName $watchdogTaskName -Confirm:$false -ErrorAction SilentlyContinue

$watchdogScript  = Join-Path $InstallDir 'Watchdog-Tray.ps1'
$watchdogAction  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watchdogScript`""
# Bei der Anmeldung und danach alle 5 Minuten pruefen.
$watchdogTriggers = @(
    (New-ScheduledTaskTrigger -AtLogOn -User $UserId),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) `
        -RepetitionInterval (New-TimeSpan -Minutes 5) `
        -RepetitionDuration (New-TimeSpan -Days 365))
)
$watchdogPrincipal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $watchdogTaskName -Action $watchdogAction -Trigger $watchdogTriggers `
    -Principal $watchdogPrincipal -Settings $taskSettings `
    -Description 'PowerProfile Switcher: startet das Tray-Icon neu, falls es nicht mehr laeuft' | Out-Null
}

# --- Desktop-Verknuepfungen -------------------------------------------
function New-ProfileShortcut {
    param([string]$Path, [string]$TaskName, [string]$Description)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -Command `"Start-ScheduledTask -TaskName '$TaskName'`""
    $shortcut.Description = $Description
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

function New-AppShortcut {
    param([string]$Path, [string]$Target, [string]$Description)

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Target`""
    $shortcut.Description = $Description
    $shortcut.WindowStyle = 7
    $shortcut.Save()
}

$Desktop      = [Environment]::GetFolderPath('Desktop')
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'PowerProfile Switcher'
New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null

# Hauptfenster - der uebliche Weg, die App zu bedienen
Write-Info 'Erstelle Verknuepfung fuer das Programmfenster ...'
$windowScript = Join-Path $InstallDir 'Show-PowerWindow.ps1'
foreach ($dir in $Desktop, $StartMenuDir) {
    New-AppShortcut -Path (Join-Path $dir 'PowerProfile Switcher.lnk') -Target $windowScript `
        -Description 'PowerProfile Switcher - Profile umschalten und einstellen'
}

Write-Info 'Erstelle Verknuepfungen auf Desktop und im Startmenue ...'
foreach ($p in $ProfileDefinitions.Keys) {
    $def  = $ProfileDefinitions[$p]
    $file = "$($def.ShortcutName).lnk"
    $desc = "Energieprofil: $($def.DisplayName)"
    New-ProfileShortcut -Path (Join-Path $Desktop $file)      -TaskName "PowerProfileSwitcher-$p" -Description $desc
    New-ProfileShortcut -Path (Join-Path $StartMenuDir $file) -TaskName "PowerProfileSwitcher-$p" -Description $desc
}

# --- Tray-Icon direkt jetzt schon starten ------------------------------
if ($installTray) {
    Write-Info 'Starte Tray-Icon ...'
    try {
        Start-ScheduledTask -TaskName $trayTaskName
    } catch {
        Write-Warning 'Tray-Icon konnte nicht sofort gestartet werden, wird aber ab der naechsten Anmeldung automatisch starten.'
    }
}

Write-Host ''
Write-Host '===========================================================' -ForegroundColor Green
Write-Host ' Installation abgeschlossen!' -ForegroundColor Green
Write-Host ' Auf dem Desktop liegt jetzt "PowerProfile Switcher" - das' -ForegroundColor Green
Write-Host ' Programmfenster mit allen Profilen, Einstellungen und Werkzeugen.' -ForegroundColor Green
Write-Host ''
Write-Host ' Zusaetzlich je eine Verknuepfung zum Direkt-Umschalten:' -ForegroundColor Green
foreach ($p in $ProfileDefinitions.Keys) {
    Write-Host ("   - {0}" -f $ProfileDefinitions[$p].ShortcutName) -ForegroundColor Green
}
if ($installTray) {
    Write-Host '' -ForegroundColor Green
    Write-Host ' Zusaetzlich laeuft ab jetzt ein Tray-Icon (unten rechts) -' -ForegroundColor Green
    Write-Host ' es startet bei jeder Anmeldung und liefert Watt-Anzeige,' -ForegroundColor Green
    Write-Host ' Protokoll und automatisches Umschalten.' -ForegroundColor Green
} else {
    Write-Host '' -ForegroundColor Green
    Write-Host ' Es laeuft KEIN Hintergrundprozess. Watt-Anzeige, Protokoll und' -ForegroundColor Green
    Write-Host ' automatisches Umschalten brauchen das Tray-Icon - dafuer die' -ForegroundColor Green
    Write-Host ' Installation mit  -WithTray  wiederholen.' -ForegroundColor Green
}
Write-Host '===========================================================' -ForegroundColor Green
Write-Host ''
Read-Host 'Enter druecken zum Schliessen'
