#Requires -Version 5.1
<#
    Uninstall.ps1

    Entfernt alle von Install.ps1 angelegten geplanten Aufgaben und
    Verknuepfungen, beendet das Tray-Icon und setzt das aktive
    Energieschema auf 'Ausbalanciert' zurueck. Fragt, ob die selbst
    erstellten Energieschemata (Gaming/Travel) ebenfalls geloescht werden
    sollen.
#>

$ErrorActionPreference = 'SilentlyContinue'

function Write-Info($Text) { Write-Host "[Uninstall] $Text" -ForegroundColor Cyan }

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

$InstallDir = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$StateFile  = Join-Path $InstallDir 'schemes.json'

# --- Tray-Icon beenden --------------------------------------------------
Write-Info 'Beende laufendes Tray-Icon (falls aktiv) ...'
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# --- Geplante Aufgaben entfernen ----------------------------------------
foreach ($task in 'PowerProfileSwitcher-Gaming', 'PowerProfileSwitcher-Balanced', 'PowerProfileSwitcher-Travel',
                  'PowerProfileSwitcher-Travel-NoGpu', 'PowerProfileSwitcher-Tray') {
    Write-Info "Entferne geplante Aufgabe '$task' ..."
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
}

# --- Verknuepfungen entfernen --------------------------------------------
$Desktop = [Environment]::GetFolderPath('Desktop')
foreach ($name in 'Gaming - Hoechstleistung.lnk', 'Ausgeglichen.lnk', 'Unterwegs - Akku sparen.lnk') {
    $path = Join-Path $Desktop $name
    if (Test-Path $path) {
        Write-Info "Entferne Verknuepfung '$name' ..."
        Remove-Item -Path $path -Force
    }
}

$StartMenuDir = Join-Path ([Environment]::GetFolderPath('Programs')) 'PowerProfile Switcher'
if (Test-Path $StartMenuDir) {
    Write-Info 'Entferne Startmenue-Ordner ...'
    Remove-Item -Path $StartMenuDir -Recurse -Force
}

# --- Pausierte Hintergrunddienste wieder freigeben -----------------------
$servicesFile = Join-Path $InstallDir 'services.json'
if (Test-Path $servicesFile) {
    try {
        foreach ($name in @(Get-Content $servicesFile -Raw | ConvertFrom-Json)) {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running' -and $svc.StartType -ne 'Disabled') {
                Write-Info "Starte pausierten Dienst '$name' wieder ..."
                Start-Service -Name $name -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# --- Aktives Schema zuruecksetzen und eigene Schemata optional loeschen ---
Write-Info "Setze aktives Energieschema auf 'Ausbalanciert' zurueck ..."
powercfg /setactive SCHEME_BALANCED 2>&1 | Out-Null

if (Test-Path $StateFile) {
    try {
        $state = Get-Content $StateFile -Raw | ConvertFrom-Json
        $answer = Read-Host 'Sollen die eigens erstellten Energieschemata (Gaming/Unterwegs) ebenfalls geloescht werden? (j/N)'
        if ($answer -match '^[jJ]') {
            foreach ($prop in $state.PSObject.Properties) {
                Write-Info "Loesche Energieschema fuer '$($prop.Name)' ..."
                powercfg /delete $prop.Value 2>&1 | Out-Null
            }
        }
    } catch { }
}

# --- Installationsordner entfernen ---------------------------------------
if (Test-Path $InstallDir) {
    Write-Info 'Entferne Installationsordner ...'
    Remove-Item -Path $InstallDir -Recurse -Force
}

Write-Host ''
Write-Host 'PowerProfile Switcher wurde vollstaendig entfernt.' -ForegroundColor Green
Read-Host 'Enter druecken zum Schliessen'
