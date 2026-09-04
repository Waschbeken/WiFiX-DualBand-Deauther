#Requires -Version 5.1
<#
    Show-PowerStatus.ps1

    Zeigt den tatsaechlichen Ist-Zustand des Systems - nicht die Sollwerte
    aus den Profilen. Also: was ist gerade wirklich eingestellt?

    Dazu eine Vorschau je Profil: was wuerde sich aendern, wenn ich jetzt
    daraufklicke? So sieht man vor dem Umschalten, was passiert.

    Braucht keine Administratorrechte.
#>

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$StateDir     = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$CurrentFile  = Join-Path $StateDir 'current.json'
$ServicesFile = Join-Path $StateDir 'services.json'

. (Join-Path $PSScriptRoot 'Profiles.ps1')
. (Join-Path $PSScriptRoot 'PowerDisplay.ps1')

$MetricsScript = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
if (Test-Path $MetricsScript) { . $MetricsScript }

# --- Ist-Zustand einsammeln ----------------------------------------------
$currentMode = $null
try { $currentMode = (Get-Content $CurrentFile -Raw | ConvertFrom-Json).Mode } catch { }

$activeScheme = 'unbekannt'
try {
    $out = (powercfg /getactivescheme 2>&1 | Out-String).Trim()
    $m = [regex]::Match($out, '\(([^)]+)\)')
    if ($m.Success) { $activeScheme = $m.Groups[1].Value } else { $activeScheme = $out }
} catch { }

$currentHz  = Get-CurrentDisplayRate
$resolution = Get-CurrentDisplayResolution
$rates      = Get-DisplayRates

$currentBrightness = -1
try {
    $b = Get-WmiObject -Namespace root/WMI -Class WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
    if ($b) { $currentBrightness = [int]$b.CurrentBrightness }
} catch { }

$gpu = $null
try {
    $gpu = Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
           Where-Object { $_.FriendlyName -match 'NVIDIA|Radeon RX|Radeon Pro|Radeon\s*\d{3,4}' } |
           Select-Object -First 1
} catch { }
$gpuActive = $null
if ($gpu) { $gpuActive = ($gpu.Status -eq 'OK') }

$pausedServices = @()
if (Test-Path $ServicesFile) {
    try {
        foreach ($name in @(Get-Content $ServicesFile -Raw | ConvertFrom-Json)) {
            $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Running') { $pausedServices += $name }
        }
    } catch { }
}

$battery = $null
if (Get-Command Get-BatteryReading -ErrorAction SilentlyContinue) { $battery = Get-BatteryReading }

# --- Text aufbauen --------------------------------------------------------
$lines = @()
$lines += '== Aktueller Systemzustand =='
$lines += ''
if ($currentMode -and $ProfileDefinitions.Contains($currentMode)) {
    $lines += ('Zuletzt gewaehltes Profil : {0}' -f $ProfileDefinitions[$currentMode].DisplayName)
} else {
    $lines += 'Zuletzt gewaehltes Profil : keines (noch nicht umgeschaltet)'
}
$lines += ('Aktives Energieschema    : {0}' -f $activeScheme)
$lines += ('Bildschirm               : {0} @ {1} Hz' -f $resolution, $currentHz)
if ($rates.Count -gt 0) {
    $lines += ('  moegliche Frequenzen   : ' + (($rates | ForEach-Object { "$_" }) -join ', ') + ' Hz')
}
if ($currentBrightness -ge 0) { $lines += ('Helligkeit               : {0} %' -f $currentBrightness) }
else                          { $lines += 'Helligkeit               : nicht auslesbar (externer Monitor?)' }

if ($gpu) {
    $gpuText = if ($gpuActive) { 'aktiv' } else { "deaktiviert (Status $($gpu.Status))" }
    $lines += ('Dedizierte GPU           : {0} - {1}' -f $gpu.FriendlyName, $gpuText)
} else {
    $lines += 'Dedizierte GPU           : keine erkannt'
}

if ($pausedServices.Count -gt 0) {
    $lines += ('Pausierte Dienste        : ' + ($pausedServices -join ', '))
} else {
    $lines += 'Pausierte Dienste        : keine'
}

if ($battery) {
    $src = if ($battery.OnAc) { 'Netzteil' } else { 'Akku' }
    $wattText = if ($battery.DrawWatt -gt 0) { ', {0:N1} W' -f $battery.DrawWatt } else { '' }
    $lines += ('Stromquelle              : {0} - {1} %{2}' -f $src, $battery.Percent, $wattText)
}

# --- Vorschau je Profil ---------------------------------------------------
$lines += ''
$lines += '== Was wuerde ein Klick aendern? =='

foreach ($key in $ProfileDefinitions.Keys) {
    $def = $ProfileDefinitions[$key]
    $changes = @()

    if ($def.Hertz -gt 0 -and $currentHz -gt 0 -and $def.Hertz -ne $currentHz) {
        if ($rates.Count -gt 0 -and ($rates -notcontains [int]$def.Hertz)) {
            $changes += ('{0} -> {1} Hz (Panel bietet {1} Hz NICHT an)' -f $currentHz, $def.Hertz)
        } else {
            $changes += ('{0} -> {1} Hz' -f $currentHz, $def.Hertz)
        }
    }
    if ($def.Brightness -gt 0 -and $currentBrightness -ge 0 -and [int]$def.Brightness -ne $currentBrightness) {
        $changes += ('Helligkeit {0} -> {1} %' -f $currentBrightness, $def.Brightness)
    }
    if ($null -ne $def.DiscreteGpu -and $null -ne $gpuActive -and ([bool]$def.DiscreteGpu -ne $gpuActive)) {
        $changes += $(if ($def.DiscreteGpu) { 'GPU wird eingeschaltet' } else { 'GPU wird abgeschaltet (Neustart-Abfrage)' })
    }
    if ($def.PauseBackground -and $pausedServices.Count -eq 0) {
        $changes += 'Hintergrunddienste werden pausiert'
    }
    if (-not $def.PauseBackground -and $pausedServices.Count -gt 0) {
        $changes += 'Pausierte Dienste werden wieder gestartet'
    }

    $cpuDc = $null
    foreach ($entry in $def.Settings) {
        if ($entry.Setting -contains 'PROCTHROTTLEMAX') { $cpuDc = [int]$entry.Dc }
    }
    if ($null -ne $cpuDc) { $changes += ('CPU-Maximum im Akkubetrieb: {0} %' -f $cpuDc) }

    $lines += ''
    $marker = if ($key -eq $currentMode) { ' (aktuell gewaehlt)' } else { '' }
    $lines += ('{0}{1}:' -f $def.DisplayName, $marker)
    if ($changes.Count -eq 0) {
        $lines += '  keine sichtbaren Aenderungen'
    } else {
        foreach ($c in $changes) { $lines += "  - $c" }
    }
}

$lines += ''
$lines += 'Hinweis: Zeiten (Bildschirm aus, Standby), WLAN- und PCIe-Sparmodus'
$lines += 'werden ebenfalls gesetzt, lassen sich aber nicht direkt auslesen -'
$lines += 'dafuer gibt es die Diagnose.'

# --- Anzeige in einem scrollbaren Fenster --------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PowerProfile Switcher - Systemzustand'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(620, 560)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Multiline = $true
$textBox.ScrollBars = 'Vertical'
$textBox.ReadOnly = $true
$textBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$textBox.Dock = 'Fill'
$textBox.Text = ($lines -join "`r`n")
$form.Controls.Add($textBox)

$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = 'Bottom'
$panel.Height = 44

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = 'Schliessen'
$btnClose.Size = New-Object System.Drawing.Size(100, 28)
$btnClose.Location = New-Object System.Drawing.Point(508, 8)
$btnClose.Anchor = 'Bottom,Right'
$btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
$panel.Controls.Add($btnClose)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = 'In Zwischenablage'
$btnCopy.Size = New-Object System.Drawing.Size(140, 28)
$btnCopy.Location = New-Object System.Drawing.Point(12, 8)
$btnCopy.Anchor = 'Bottom,Left'
$btnCopy.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($textBox.Text) } catch { } })
$panel.Controls.Add($btnCopy)

$form.Controls.Add($panel)
$form.AcceptButton = $btnClose
[void]$form.ShowDialog()
