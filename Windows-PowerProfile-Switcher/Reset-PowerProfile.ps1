#Requires -Version 5.1
<#
    Reset-PowerProfile.ps1

    Notfall-Reset: dreht alles zurueck, was die App am System geaendert
    haben kann. Gedacht fuer den Fall, dass etwas haengen bleibt - z.B.
    die dedizierte GPU noch deaktiviert ist, Dienste pausiert sind oder
    der Bildschirm dunkel/auf 60 Hz steht.

    Zurueckgesetzt wird:
      - dedizierte GPU wieder aktivieren
      - von der App pausierte Dienste wieder starten
      - Windows-Standardschema "Ausbalanciert" aktivieren
      - Helligkeit auf 80 %, Bildwiederholrate auf den hoechsten Wert
      - auf Wunsch: eigene Energieschemata und eigene Anpassungen loeschen

    Braucht Administratorrechte (elevatiert sich selbst).
#>

param(
    # Ohne Rueckfragen durchlaufen.
    [switch]$Force
)

$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

function Show-Box {
    param([string]$Text, [string]$Icon = 'Information')
    Write-Host $Text
    try {
        $iconValue = [System.Windows.Forms.MessageBoxIcon]$Icon
        [System.Windows.Forms.MessageBox]::Show($Text, 'PowerProfile Switcher - Zuruecksetzen',
            [System.Windows.Forms.MessageBoxButtons]::OK, $iconValue) | Out-Null
    } catch { }
}

# --- Selbst-Elevation ----------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptPath`"")
    if ($Force) { $argList += '-Force' }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

$StateDir     = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$SchemesFile  = Join-Path $StateDir 'schemes.json'
$ServicesFile = Join-Path $StateDir 'services.json'
$OverrideFile = Join-Path $StateDir 'profile-overrides.json'
$CurrentFile  = Join-Path $StateDir 'current.json'
$BackupFile   = Join-Path $StateDir 'backup-original-scheme.pow'

. (Join-Path $PSScriptRoot 'PowerDisplay.ps1')

if (-not $Force) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Alles zuruecksetzen?`n`n" +
        "- dedizierte GPU wieder aktivieren`n" +
        "- pausierte Hintergrunddienste wieder starten`n" +
        "- Energieschema auf 'Ausbalanciert' (Windows-Standard)`n" +
        "- Helligkeit 80 %, hoechste Bildwiederholrate`n`n" +
        "Deine Messdaten und Berichte bleiben erhalten.",
        'PowerProfile Switcher - Zuruecksetzen',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
}

$done = @()
$failed = @()

# --- 1) Dedizierte GPU wieder aktivieren ---------------------------------
try {
    $gpu = Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
           Where-Object { $_.FriendlyName -match 'NVIDIA|Radeon RX|Radeon Pro|Radeon\s*\d{3,4}' } |
           Select-Object -First 1
    if (-not $gpu) {
        $done += 'Keine dedizierte GPU gefunden - nichts zu tun.'
    } elseif ($gpu.Status -eq 'OK') {
        $done += "Dedizierte GPU war bereits aktiv ($($gpu.FriendlyName))."
    } else {
        & pnputil.exe /enable-device $gpu.InstanceId 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $done += "Dedizierte GPU aktiviert ($($gpu.FriendlyName))." }
        else { $failed += 'Die dedizierte GPU konnte nicht aktiviert werden - bitte im Geraete-Manager pruefen.' }
    }
} catch {
    $failed += "GPU-Status konnte nicht gelesen werden: $_"
}

# --- 2) Pausierte Dienste wieder starten ---------------------------------
if (Test-Path $ServicesFile) {
    try {
        $stopped = @(Get-Content $ServicesFile -Raw | ConvertFrom-Json)
        foreach ($name in $stopped) {
            try {
                $svc = Get-Service -Name $name -ErrorAction Stop
                if ($svc.StartType -eq 'Disabled') {
                    $failed += "Dienst '$name' ist deaktiviert und wurde nicht gestartet."
                } elseif ($svc.Status -ne 'Running') {
                    Start-Service -Name $name -ErrorAction Stop
                    $done += "Dienst '$name' wieder gestartet."
                } else {
                    $done += "Dienst '$name' lief bereits."
                }
            } catch {
                $failed += "Dienst '$name' konnte nicht gestartet werden: $_"
            }
        }
        '[]' | Set-Content -Path $ServicesFile -Encoding UTF8
    } catch {
        $failed += "Dienstliste konnte nicht gelesen werden: $_"
    }
} else {
    $done += 'Es waren keine Dienste pausiert.'
}

# --- 3) Windows-Standardschema aktivieren --------------------------------
powercfg /setactive SCHEME_BALANCED 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) { $done += "Energieschema auf 'Ausbalanciert' gesetzt." }
else { $failed += 'Das Standardschema konnte nicht aktiviert werden.' }

# --- 4) Helligkeit und Bildwiederholrate ---------------------------------
try {
    $monitor = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightnessMethods -ErrorAction Stop
    $monitor.WmiSetBrightness(1, 80) | Out-Null
    $done += 'Helligkeit auf 80 % gesetzt.'
} catch {
    $failed += 'Helligkeit konnte nicht gesetzt werden (externer Monitor?).'
}

$rates = Get-DisplayRates
if ($rates.Count -gt 0) {
    $maxRate = ($rates | Measure-Object -Maximum).Maximum
    $current = Get-CurrentDisplayRate
    if ($current -eq $maxRate) {
        $done += "Bildwiederholrate stand bereits auf $maxRate Hz."
    } else {
        $result = [PowerProfileSwitcher.DisplayInfo]::SetRate($maxRate)
        if ($result -eq 0) { $done += "Bildwiederholrate auf $maxRate Hz gesetzt." }
        else { $failed += "Bildwiederholrate konnte nicht auf $maxRate Hz gesetzt werden (Code $result)." }
    }
} else {
    $failed += 'Die moeglichen Bildwiederholraten konnten nicht ermittelt werden.'
}

# --- 5) Optional: eigene Schemata und Anpassungen entfernen --------------
$removeExtras = $false
if (-not $Force) {
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Sollen auch die von der App angelegten Energieschemata (XMG Gaming, XMG Unterwegs, XMG Video) und deine eigenen Anpassungen geloescht werden?`n`nNein = nur zuruecksetzen, Profile bleiben nutzbar.",
        'PowerProfile Switcher - Zuruecksetzen',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    $removeExtras = ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

if ($removeExtras) {
    if (Test-Path $SchemesFile) {
        try {
            $schemes = Get-Content $SchemesFile -Raw | ConvertFrom-Json
            foreach ($prop in $schemes.PSObject.Properties) {
                powercfg /delete $prop.Value 2>&1 | Out-Null
                $done += "Energieschema fuer '$($prop.Name)' geloescht."
            }
            Remove-Item $SchemesFile -Force -ErrorAction SilentlyContinue
        } catch {
            $failed += "Eigene Energieschemata konnten nicht geloescht werden: $_"
        }
    }
    foreach ($file in $OverrideFile, $CurrentFile) {
        if (Test-Path $file) {
            Remove-Item $file -Force -ErrorAction SilentlyContinue
            $done += "$(Split-Path -Leaf $file) entfernt."
        }
    }
}

# --- Ergebnis ------------------------------------------------------------
$lines = @('Zuruecksetzen abgeschlossen.', '')
$lines += 'Erledigt:'
foreach ($d in $done) { $lines += "  - $d" }
if ($failed.Count -gt 0) {
    $lines += ''
    $lines += 'Nicht moeglich:'
    foreach ($f in $failed) { $lines += "  - $f" }
}
if (Test-Path $BackupFile) {
    $lines += ''
    $lines += 'Deine urspruenglichen Energieeinstellungen liegen als Sicherung unter:'
    $lines += "  $BackupFile"
    $lines += 'Wiederherstellen mit:  powercfg /import "' + $BackupFile + '"'
}

Show-Box -Text ($lines -join "`n")
