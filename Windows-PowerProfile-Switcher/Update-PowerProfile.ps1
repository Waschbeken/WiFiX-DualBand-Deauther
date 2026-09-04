#Requires -Version 5.1
<#
    Update-PowerProfile.ps1

    Holt die neueste Fassung der Skripte aus dem GitHub-Repository, vergleicht
    die Versionsnummer mit der installierten und bietet die Aktualisierung an.
    Installiert wird ueber das mitgelieferte Install.ps1, das sich bei Bedarf
    selbst auf Administratorrechte hebt.

    Es wird ausschliesslich das offizielle GitHub-Archiv geladen; ausgefuehrt
    wird nur, was der Benutzer im Dialog bestaetigt.
#>

param(
    # Ohne Rueckfrage aktualisieren (fuer eigene geplante Aufgaben).
    [switch]$Silent,

    # Nur pruefen und Version melden, nichts installieren.
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

# Quellen in dieser Reihenfolge probieren (Entwicklungszweig, dann Hauptzweig).
$ArchiveUrls = @(
    'https://github.com/Waschbeken/WiFiX-DualBand-Deauther/archive/refs/heads/claude/windows-power-profile-switcher-v599z0.zip',
    'https://github.com/Waschbeken/WiFiX-DualBand-Deauther/archive/refs/heads/main.zip'
)

$InstalledVersion = '0.0.0'
$LocalProfiles = Join-Path $PSScriptRoot 'Profiles.ps1'
if (Test-Path $LocalProfiles) { . $LocalProfiles }
if ($PowerProfileVersion) { $InstalledVersion = $PowerProfileVersion }

function Show-Info {
    param([string]$Text, [string]$Title = 'PowerProfile Switcher - Update')
    Write-Host "[Update] $Text"
    if ($Silent) { return }
    try {
        [System.Windows.Forms.MessageBox]::Show($Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch { }
}

function Get-VersionFromFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $match = Select-String -Path $Path -Pattern "^\s*\`$PowerProfileVersion\s*=\s*'([^']+)'" -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($match) { return $match.Matches[0].Groups[1].Value }
    return $null
}

function Test-NewerVersion {
    param([string]$Remote, [string]$Local)
    try { return ([version]$Remote -gt [version]$Local) } catch { return ($Remote -ne $Local) }
}

# --- Herunterladen -------------------------------------------------------
$tempRoot = Join-Path $env:TEMP ('PowerProfileUpdate_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$zipPath = Join-Path $tempRoot 'update.zip'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

$downloaded = $false
foreach ($url in $ArchiveUrls) {
    try {
        Write-Host "[Update] Lade $url ..."
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
        $downloaded = $true
        break
    } catch {
        Write-Warning "Quelle nicht erreichbar: $_"
    }
}

if (-not $downloaded) {
    Show-Info 'Der Update-Server ist nicht erreichbar. Bitte Internetverbindung pruefen und spaeter erneut versuchen.'
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

# --- Entpacken und Version vergleichen -----------------------------------
$extractDir = Join-Path $tempRoot 'extract'
try {
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force -ErrorAction Stop
} catch {
    Show-Info "Das heruntergeladene Archiv konnte nicht entpackt werden: $_"
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$sourceDir = Get-ChildItem -Path $extractDir -Directory -Recurse -Filter 'Windows-PowerProfile-Switcher' |
             Select-Object -First 1
if (-not $sourceDir) {
    Show-Info 'Im heruntergeladenen Archiv wurde der Ordner "Windows-PowerProfile-Switcher" nicht gefunden.'
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

$remoteVersion = Get-VersionFromFile -Path (Join-Path $sourceDir.FullName 'Profiles.ps1')
if (-not $remoteVersion) {
    Show-Info 'Die Version der heruntergeladenen Fassung konnte nicht gelesen werden.'
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "[Update] Installiert: $InstalledVersion, verfuegbar: $remoteVersion"

if (-not (Test-NewerVersion -Remote $remoteVersion -Local $InstalledVersion)) {
    Show-Info "Du hast bereits die neueste Version ($InstalledVersion)."
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

if ($CheckOnly) {
    Show-Info "Version $remoteVersion ist verfuegbar (installiert: $InstalledVersion)."
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# --- Installation anbieten -----------------------------------------------
$install = $true
if (-not $Silent) {
    try {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Neue Version verfuegbar: $remoteVersion`nInstalliert: $InstalledVersion`n`nJetzt aktualisieren? Dabei erscheint einmal die Administrator-Abfrage von Windows; das Tray-Icon startet anschliessend neu.",
            'PowerProfile Switcher - Update',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        $install = ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        $install = $false
    }
}

if (-not $install) {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

$installer = Join-Path $sourceDir.FullName 'Install.ps1'
if (-not (Test-Path $installer)) {
    Show-Info 'Im Archiv fehlt Install.ps1 - Update abgebrochen.'
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}

Write-Host '[Update] Starte Installation ...'
try {
    # Install.ps1 hebt sich selbst auf Administratorrechte und startet das
    # Tray-Icon danach neu. Auf den Abschluss warten, damit anschliessend
    # aufgeraeumt werden kann.
    $proc = Start-Process -FilePath 'powershell.exe' -PassThru -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$installer`""
    )
    Write-Host "[Update] Installation beendet (Code $($proc.ExitCode))."
} catch {
    Show-Info "Die Installation konnte nicht gestartet werden: $_"
}

Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
