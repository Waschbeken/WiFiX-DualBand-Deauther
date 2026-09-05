#Requires -Version 5.1
<#
    Uninstall.ps1

    Entfernt alles, was Install.ps1 angelegt hat: geplante Aufgaben,
    Verknuepfungen, das Startprogramm, den Startmenue-Ordner und den
    Installationsordner. Gibt pausierte Dienste wieder frei und setzt das
    Energieschema auf "Ausbalanciert" zurueck.

    Das Fenster bleibt in jedem Fall offen, bis du Enter drueckst - auch
    wenn unterwegs etwas schiefgeht. Zusaetzlich wird alles nach
    %TEMP%\PowerProfileSwitcher-Uninstall.log geschrieben.

    Am einfachsten per Doppelklick auf "Deinstallieren.bat" starten.
#>

param(
    # Ohne Rueckfragen durchlaufen (loescht dann auch die eigenen Schemata).
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

$LogPath = Join-Path $env:TEMP 'PowerProfileSwitcher-Uninstall.log'

function Write-Info {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host "[Uninstall] $Text" -ForegroundColor $Color
    try { "$(Get-Date -Format 'HH:mm:ss')  $Text" | Add-Content -Path $LogPath -Encoding UTF8 } catch { }
}

function Wait-Before-Exit {
    Write-Host ''
    Write-Host "Protokoll: $LogPath" -ForegroundColor DarkGray
    try { Read-Host 'Enter druecken zum Schliessen' | Out-Null } catch { Start-Sleep -Seconds 20 }
}

try { "=== $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Add-Content -Path $LogPath -Encoding UTF8 } catch { }

# --- Selbst-Elevation ----------------------------------------------------
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {

    # Den eigenen Pfad zuverlaessig bestimmen - je nach Startart ist mal die
    # eine, mal die andere Variable gefuellt.
    $scriptPath = $PSCommandPath
    if (-not $scriptPath) { $scriptPath = $MyInvocation.MyCommand.Path }
    if (-not $scriptPath) { $scriptPath = Join-Path (Get-Location).Path 'Uninstall.ps1' }

    if (-not (Test-Path $scriptPath)) {
        Write-Host "Das Skript konnte sich selbst nicht finden ($scriptPath)." -ForegroundColor Red
        Write-Host 'Bitte den Ordner entpacken und "Deinstallieren.bat" per Doppelklick starten.' -ForegroundColor Yellow
        Wait-Before-Exit
        exit 1
    }

    Write-Host 'Fuer das Entfernen sind Administratorrechte noetig - bitte die Abfrage von Windows bestaetigen.'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
    if ($Force) { $argList += '-Force' }

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -ErrorAction Stop
        exit 0
    } catch {
        Write-Host ''
        Write-Host 'Der Start mit Administratorrechten wurde abgebrochen oder ist fehlgeschlagen:' -ForegroundColor Red
        Write-Host "  $_" -ForegroundColor Red
        Write-Host ''
        Write-Host 'Alternative: PowerShell als Administrator oeffnen und dort ausfuehren:' -ForegroundColor Yellow
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$scriptPath`"" -ForegroundColor Yellow
        Wait-Before-Exit
        exit 1
    }
}

# --------------------------------------------------------------------------
# Ab hier mit Administratorrechten
# --------------------------------------------------------------------------
$InstallDir   = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$StateFile    = Join-Path $InstallDir 'schemes.json'
$ServicesFile = Join-Path $InstallDir 'services.json'
$removed = 0
$problems = @()

try {
    Write-Host ''
    Write-Host '=== PowerProfile Switcher entfernen ===' -ForegroundColor White
    Write-Host ''

    # --- Laufende Prozesse der App beenden --------------------------------
    Write-Info 'Beende laufende Teile der App ...'
    foreach ($pattern in '*Start-Tray.ps1*', '*Show-PowerWindow.ps1*') {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like $pattern } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Get-Process -Name 'PowerProfileSwitcher' -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    # --- Geplante Aufgaben ------------------------------------------------
    foreach ($task in 'PowerProfileSwitcher-Gaming', 'PowerProfileSwitcher-Balanced',
                      'PowerProfileSwitcher-Travel', 'PowerProfileSwitcher-Video',
                      'PowerProfileSwitcher-Travel-NoGpu', 'PowerProfileSwitcher-Tray',
                      'PowerProfileSwitcher-Watchdog') {
        $existing = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        if ($existing) {
            try {
                Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop
                Write-Info "Aufgabe '$task' entfernt."
                $removed++
            } catch {
                $problems += "Aufgabe '$task': $_"
            }
        }
    }

    # --- Verknuepfungen und Startprogramm ---------------------------------
    $Desktop = [Environment]::GetFolderPath('Desktop')
    foreach ($name in 'Gaming - Hoechstleistung.lnk', 'Ausgeglichen.lnk', 'Unterwegs - Akku sparen.lnk',
                      'Video - Bildschirm bleibt an.lnk', 'PowerProfile Switcher.lnk',
                      'PowerProfile Switcher.exe') {
        $path = Join-Path $Desktop $name
        if (Test-Path $path) {
            try {
                Remove-Item -Path $path -Force -ErrorAction Stop
                Write-Info "'$name' vom Desktop entfernt."
                $removed++
            } catch {
                $problems += "Desktop-Datei '$name': $_"
            }
        }
    }

    $StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'PowerProfile Switcher'
    if (Test-Path $StartMenuDir) {
        try {
            Remove-Item -Path $StartMenuDir -Recurse -Force -ErrorAction Stop
            Write-Info 'Startmenue-Ordner entfernt.'
            $removed++
        } catch {
            $problems += "Startmenue-Ordner: $_"
        }
    }

    # --- Pausierte Dienste wieder freigeben -------------------------------
    if (Test-Path $ServicesFile) {
        try {
            foreach ($name in @(Get-Content $ServicesFile -Raw | ConvertFrom-Json)) {
                $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Running' -and $svc.StartType -ne 'Disabled') {
                    Start-Service -Name $name -ErrorAction SilentlyContinue
                    Write-Info "Dienst '$name' wieder gestartet."
                }
            }
        } catch {
            $problems += "Dienste: $_"
        }
    }

    # --- Dedizierte GPU sicherheitshalber wieder aktivieren ---------------
    try {
        $gpu = Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
               Where-Object { $_.FriendlyName -match 'NVIDIA|Radeon RX|Radeon Pro|Radeon\s*\d{3,4}' } |
               Select-Object -First 1
        if ($gpu -and $gpu.Status -ne 'OK') {
            & pnputil.exe /enable-device $gpu.InstanceId 2>&1 | Out-Null
            Write-Info "Dedizierte GPU wieder aktiviert ($($gpu.FriendlyName))."
        }
    } catch { }

    # --- Energieschema zuruecksetzen --------------------------------------
    Write-Info "Setze Energieschema auf 'Ausbalanciert' zurueck ..."
    powercfg /setactive SCHEME_BALANCED 2>&1 | Out-Null

    # --- Eigene Schemata loeschen -----------------------------------------
    if (Test-Path $StateFile) {
        $deleteSchemes = $Force
        if (-not $Force) {
            Write-Host ''
            $answer = Read-Host 'Auch die eigenen Energieschemata (XMG Gaming/Unterwegs/Video) loeschen? (j/N)'
            $deleteSchemes = ($answer -match '^[jJ]')
        }
        if ($deleteSchemes) {
            try {
                $state = Get-Content $StateFile -Raw | ConvertFrom-Json
                foreach ($prop in $state.PSObject.Properties) {
                    powercfg /delete $prop.Value 2>&1 | Out-Null
                    Write-Info "Energieschema fuer '$($prop.Name)' geloescht."
                }
            } catch {
                $problems += "Energieschemata: $_"
            }
        } else {
            Write-Info 'Eigene Energieschemata bleiben erhalten.'
        }
    }

    # --- Installationsordner ----------------------------------------------
    if (Test-Path $InstallDir) {
        try {
            Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction Stop
            Write-Info 'Installationsordner samt Messdaten entfernt.'
            $removed++
        } catch {
            $problems += "Installationsordner ($InstallDir): $_"
        }
    }

    Write-Host ''
    if ($problems.Count -eq 0) {
        Write-Host "PowerProfile Switcher wurde entfernt ($removed Eintraege)." -ForegroundColor Green
    } else {
        Write-Host "Weitgehend entfernt ($removed Eintraege), aber Folgendes ging nicht:" -ForegroundColor Yellow
        foreach ($p in $problems) {
            Write-Host "  - $p" -ForegroundColor Yellow
            try { "PROBLEM: $p" | Add-Content -Path $LogPath -Encoding UTF8 } catch { }
        }
    }

} catch {
    Write-Host ''
    Write-Host 'Beim Entfernen ist ein Fehler aufgetreten:' -ForegroundColor Red
    Write-Host "  $_" -ForegroundColor Red
    Write-Host "  $($_.ScriptStackTrace)" -ForegroundColor DarkGray
    try {
        "FEHLER: $_" | Add-Content -Path $LogPath -Encoding UTF8
        "$($_.ScriptStackTrace)" | Add-Content -Path $LogPath -Encoding UTF8
    } catch { }
}

Wait-Before-Exit
