#Requires -Version 5.1
<#
    Backup-PowerConfig.ps1

    Sichert die komplette Konfiguration samt Messdaten in eine ZIP-Datei
    bzw. spielt sie wieder ein - fuer eine Neuinstallation von Windows
    oder einen zweiten Rechner.

    Gesichert werden die Dateien aus %LOCALAPPDATA%\PowerProfileSwitcher:
    eigene Anpassungen, Messwerte, Verbrauchsprotokoll, Akku-Verlauf,
    Leistungstests und die Sicherung der urspruenglichen Energieeinstellungen.

    Braucht keine Administratorrechte.
#>

param(
    [ValidateSet('Export', 'Import')]
    [string]$Action = 'Export'
)

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$StateDir = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# Nur Konfiguration und Daten - die Skripte selbst kommen aus dem Update.
$Patterns = @('*.json', '*.csv', '*.pow')

function Show-Box {
    param([string]$Text, [string]$Icon = 'Information')
    try {
        $iconValue = [System.Windows.Forms.MessageBoxIcon]$Icon
        [System.Windows.Forms.MessageBox]::Show($Text, 'PowerProfile Switcher - Sicherung',
            [System.Windows.Forms.MessageBoxButtons]::OK, $iconValue) | Out-Null
    } catch { Write-Host $Text }
}

function Restart-Tray {
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-ScheduledTask -TaskName 'PowerProfileSwitcher-Tray' -ErrorAction SilentlyContinue
    } catch { }
}

if ($Action -eq 'Export') {
    $files = @()
    foreach ($pattern in $Patterns) {
        $files += Get-ChildItem -Path $StateDir -Filter $pattern -File -ErrorAction SilentlyContinue
    }
    if ($files.Count -eq 0) {
        Show-Box -Text 'Es gibt noch nichts zu sichern - die App hat bisher keine Daten angelegt.' -Icon 'Warning'
        exit 0
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Title = 'Konfiguration sichern'
    $dialog.Filter = 'ZIP-Archiv (*.zip)|*.zip'
    $dialog.FileName = 'PowerProfileSwitcher-Sicherung-{0}.zip' -f (Get-Date -Format 'yyyy-MM-dd')
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }

    try {
        if (Test-Path $dialog.FileName) { Remove-Item $dialog.FileName -Force }
        Compress-Archive -Path $files.FullName -DestinationPath $dialog.FileName -Force -ErrorAction Stop
        Show-Box -Text ("Gesichert: {0} Datei(en)`n`n{1}" -f $files.Count, $dialog.FileName)
    } catch {
        Show-Box -Text "Sichern fehlgeschlagen: $_" -Icon 'Error'
    }
    exit 0
}

# --- Import ---------------------------------------------------------------
$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = 'Konfiguration wiederherstellen'
$dialog.Filter = 'ZIP-Archiv (*.zip)|*.zip'
$dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 0 }

$answer = [System.Windows.Forms.MessageBox]::Show(
    "Die Dateien aus der Sicherung ueberschreiben deine aktuellen Einstellungen und Messdaten.`n`nFortfahren?",
    'PowerProfile Switcher - Sicherung',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Warning)
if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

try {
    # Vorher eine Kopie des Ist-Zustands anlegen, damit nichts unwiederbringlich weg ist.
    $safety = Join-Path $StateDir ('vor-wiederherstellung-{0}.zip' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $existing = @()
    foreach ($pattern in $Patterns) {
        $existing += Get-ChildItem -Path $StateDir -Filter $pattern -File -ErrorAction SilentlyContinue
    }
    if ($existing.Count -gt 0) {
        Compress-Archive -Path $existing.FullName -DestinationPath $safety -Force -ErrorAction SilentlyContinue
    }

    Expand-Archive -Path $dialog.FileName -DestinationPath $StateDir -Force -ErrorAction Stop
    Restart-Tray

    $text = "Wiederhergestellt.`n`nDie Werte gelten ab dem naechsten Profilwechsel."
    if ($existing.Count -gt 0) { $text += "`n`nDein vorheriger Stand liegt sicherheitshalber unter:`n$safety" }
    Show-Box -Text $text
} catch {
    Show-Box -Text "Wiederherstellen fehlgeschlagen: $_" -Icon 'Error'
}
