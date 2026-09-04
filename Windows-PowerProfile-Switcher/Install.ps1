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

$ErrorActionPreference = 'Stop'

function Write-Info($Text) { Write-Host "[Install] $Text" -ForegroundColor Cyan }

# --- Selbst-Elevation -------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Starte erneut mit Administratorrechten ...'
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`""
    )
    exit
}

$SourceDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallDir = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$UserId     = "$env:USERDOMAIN\$env:USERNAME"

Write-Info "Installiere nach $InstallDir ..."
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

foreach ($file in 'Set-PowerProfile.ps1', 'Start-Tray.ps1', 'PowerMetrics.ps1', 'Profiles.ps1',
                  'Test-PowerProfile.ps1', 'Uninstall.ps1') {
    Copy-Item -Path (Join-Path $SourceDir $file) -Destination (Join-Path $InstallDir $file) -Force
}

$SetProfileScript = Join-Path $InstallDir 'Set-PowerProfile.ps1'
$TrayScript       = Join-Path $InstallDir 'Start-Tray.ps1'

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

# --- Geplante Aufgaben fuer die drei Profile (erhoehte Rechte, kein UAC-Prompt beim Ausloesen) ---
$profiles = @('Gaming', 'Balanced', 'Travel')

foreach ($p in $profiles) {
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

# --- Geplante Aufgabe fuer das Tray-Icon (startet bei Anmeldung, keine Admin-Rechte noetig) ---
$trayTaskName = 'PowerProfileSwitcher-Tray'
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

$Desktop = [Environment]::GetFolderPath('Desktop')
Write-Info 'Erstelle Desktop-Verknuepfungen ...'

New-ProfileShortcut -Path (Join-Path $Desktop 'Gaming - Hoechstleistung.lnk') `
    -TaskName 'PowerProfileSwitcher-Gaming' -Description 'Energieprofil: Gaming / Hoechstleistung'

New-ProfileShortcut -Path (Join-Path $Desktop 'Ausgeglichen.lnk') `
    -TaskName 'PowerProfileSwitcher-Balanced' -Description 'Energieprofil: Windows-Standard'

New-ProfileShortcut -Path (Join-Path $Desktop 'Unterwegs - Akku sparen.lnk') `
    -TaskName 'PowerProfileSwitcher-Travel' -Description 'Energieprofil: Unterwegs / Akku sparen'

# --- Startmenue-Ordner (optional, gleiche Verknuepfungen) --------------
$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'PowerProfile Switcher'
New-Item -ItemType Directory -Path $StartMenuDir -Force | Out-Null

New-ProfileShortcut -Path (Join-Path $StartMenuDir 'Gaming - Hoechstleistung.lnk') `
    -TaskName 'PowerProfileSwitcher-Gaming' -Description 'Energieprofil: Gaming / Hoechstleistung'
New-ProfileShortcut -Path (Join-Path $StartMenuDir 'Ausgeglichen.lnk') `
    -TaskName 'PowerProfileSwitcher-Balanced' -Description 'Energieprofil: Windows-Standard'
New-ProfileShortcut -Path (Join-Path $StartMenuDir 'Unterwegs - Akku sparen.lnk') `
    -TaskName 'PowerProfileSwitcher-Travel' -Description 'Energieprofil: Unterwegs / Akku sparen'

# --- Tray-Icon direkt jetzt schon starten ------------------------------
Write-Info 'Starte Tray-Icon ...'
try {
    Start-ScheduledTask -TaskName $trayTaskName
} catch {
    Write-Warning 'Tray-Icon konnte nicht sofort gestartet werden, wird aber ab der naechsten Anmeldung automatisch starten.'
}

Write-Host ''
Write-Host '===========================================================' -ForegroundColor Green
Write-Host ' Installation abgeschlossen!' -ForegroundColor Green
Write-Host ' Auf dem Desktop liegen jetzt drei Verknuepfungen:' -ForegroundColor Green
Write-Host '   - Gaming - Hoechstleistung.lnk' -ForegroundColor Green
Write-Host '   - Ausgeglichen.lnk' -ForegroundColor Green
Write-Host '   - Unterwegs - Akku sparen.lnk' -ForegroundColor Green
Write-Host ' Zusaetzlich laeuft ab jetzt ein Tray-Icon (unten rechts) mit' -ForegroundColor Green
Write-Host ' dem gleichen Menue - startet automatisch bei jeder Anmeldung,' -ForegroundColor Green
Write-Host ' bleibt auch im Akkubetrieb aktiv und startet sich bei einem' -ForegroundColor Green
Write-Host ' Absturz von selbst neu.' -ForegroundColor Green
Write-Host '===========================================================' -ForegroundColor Green
Write-Host ''
Read-Host 'Enter druecken zum Schliessen'
