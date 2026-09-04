#Requires -Version 5.1
<#
    Show-PowerSettings.ps1

    Kleines Fenster zum Anpassen der wichtigsten Profilwerte, ohne
    Profiles.ps1 im Editor bearbeiten und neu installieren zu muessen.

    Gespeichert wird nach
    %LOCALAPPDATA%\PowerProfileSwitcher\profile-overrides.json - Profiles.ps1
    liest diese Datei beim naechsten Profilwechsel und ueberschreibt damit
    seine Vorgaben. Ein Update der App ueberschreibt die Anpassungen also
    nicht.

    Braucht keine Administratorrechte.
#>

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$StateDir     = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$OverrideFile = Join-Path $StateDir 'profile-overrides.json'
$SettingsFile = Join-Path $StateDir 'settings.json'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# Vorgaben aus Profiles.ps1 lesen (inklusive bereits gespeicherter Anpassungen)
. (Join-Path $PSScriptRoot 'Profiles.ps1')

function Get-SettingValue {
    param($Definition, [string]$SettingName, [string]$Field, [int]$Fallback)
    foreach ($entry in $Definition.Settings) {
        if ($entry.Setting -contains $SettingName) { return [int]$entry[$Field] }
    }
    return $Fallback
}

$BoostLabels = @('Aus', 'Ein', 'Aggressiv')

# --- Fenster -------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'PowerProfile Switcher - Einstellungen'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(430, 660)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$controls = @{}
$y = 12

function Add-ProfileGroup {
    param(
        [string]$Key,
        [string]$Title,
        [bool]$ShowCpuAc,
        [string]$BoostField,     # 'BoostAc' oder 'BoostDc'
        [bool]$ShowCpuBoost = $true
    )

    $def = $ProfileDefinitions[$Key]

    $box = New-Object System.Windows.Forms.GroupBox
    $box.Text = $Title
    $box.Location = New-Object System.Drawing.Point(12, $script:y)
    $boxHeight = if ($ShowCpuBoost) { 156 } else { 100 }
    $box.Size = New-Object System.Drawing.Size(406, $boxHeight)

    $rowY = 24
    function New-Label {
        param([string]$Text, [int]$Top)
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.Location = New-Object System.Drawing.Point(14, ($Top + 3))
        $l.Size = New-Object System.Drawing.Size(230, 20)
        return $l
    }
    function New-Number {
        param([int]$Top, [int]$Min, [int]$Max, [int]$Value)
        $n = New-Object System.Windows.Forms.NumericUpDown
        $n.Location = New-Object System.Drawing.Point(256, $Top)
        $n.Size = New-Object System.Drawing.Size(80, 22)
        $n.Minimum = $Min
        $n.Maximum = $Max
        $n.Value = [Math]::Max($Min, [Math]::Min($Max, $Value))
        return $n
    }

    $box.Controls.Add((New-Label -Text 'Bildschirmhelligkeit (%)' -Top $rowY))
    $brightness = New-Number -Top $rowY -Min 0 -Max 100 -Value ([int]$def.Brightness)
    $box.Controls.Add($brightness)
    $rowY += 28

    $box.Controls.Add((New-Label -Text 'Bildwiederholrate (Hz, 0 = nicht aendern)' -Top $rowY))
    $hertz = New-Number -Top $rowY -Min 0 -Max 480 -Value ([int]$def.Hertz)
    $box.Controls.Add($hertz)
    $rowY += 28

    $cpu = $null
    $boost = $null
    $cpuField = if ($ShowCpuAc) { 'Ac' } else { 'Dc' }

    if ($ShowCpuBoost) {
        $cpuLabel = if ($ShowCpuAc) { 'CPU-Maximum am Netz (%)' } else { 'CPU-Maximum im Akkubetrieb (%)' }
        $box.Controls.Add((New-Label -Text $cpuLabel -Top $rowY))
        $cpu = New-Number -Top $rowY -Min 20 -Max 100 -Value (Get-SettingValue $def 'PROCTHROTTLEMAX' $cpuField 100)
        $box.Controls.Add($cpu)
        $rowY += 28

        $boostLabelText = if ($BoostField -eq 'BoostAc') { 'Turbo/Boost am Netz' } else { 'Turbo/Boost im Akkubetrieb' }
        $box.Controls.Add((New-Label -Text $boostLabelText -Top $rowY))
        $boost = New-Object System.Windows.Forms.ComboBox
        $boost.Location = New-Object System.Drawing.Point(256, $rowY)
        $boost.Size = New-Object System.Drawing.Size(134, 22)
        $boost.DropDownStyle = 'DropDownList'
        [void]$boost.Items.AddRange($BoostLabels)
        $boostFieldName = if ($BoostField -eq 'BoostAc') { 'Ac' } else { 'Dc' }
        $boostValue = Get-SettingValue $def 'PERFBOOSTMODE' $boostFieldName 1
        if ($boostValue -lt 0 -or $boostValue -gt 2) { $boostValue = 1 }
        $boost.SelectedIndex = $boostValue
        $box.Controls.Add($boost)
        $rowY += 28
    }

    $throttle = New-Object System.Windows.Forms.CheckBox
    $throttle.Text = 'Hintergrund-Dienste bremsen (Suche, Update-Auslieferung)'
    $throttle.Location = New-Object System.Drawing.Point(14, $rowY)
    $throttle.Size = New-Object System.Drawing.Size(380, 22)
    $throttle.Checked = [bool]$def.PauseBackground
    $box.Controls.Add($throttle)

    $form.Controls.Add($box)
    $script:y += ($boxHeight + 10)

    $script:controls[$Key] = @{
        Brightness = $brightness
        Hertz      = $hertz
        Cpu        = $cpu
        CpuField   = $cpuField
        Boost      = $boost
        BoostKey   = $BoostField
        Throttle   = $throttle
    }
}

Add-ProfileGroup -Key 'Gaming'   -Title 'Gaming (Hoechstleistung)' -ShowCpuAc $true  -BoostField 'BoostAc'
# Ausgeglichen nutzt bewusst das unveraenderte Windows-Schema - dort gibt es
# keine eigenen CPU-Werte, die man sinnvoll setzen koennte.
Add-ProfileGroup -Key 'Balanced' -Title 'Ausgeglichen (Windows-Standard)' -ShowCpuAc $false -BoostField 'BoostDc' -ShowCpuBoost $false
Add-ProfileGroup -Key 'Travel'   -Title 'Unterwegs (Akku sparen)'  -ShowCpuAc $false -BoostField 'BoostDc'

# --- Allgemeines ---------------------------------------------------------
$globalBox = New-Object System.Windows.Forms.GroupBox
$globalBox.Text = 'Allgemein'
$globalBox.Location = New-Object System.Drawing.Point(12, $y)
$globalBox.Size = New-Object System.Drawing.Size(406, 90)

$minLabel = New-Object System.Windows.Forms.Label
$minLabel.Text = 'Gaming erst ab Akkustand (%, 0 = Regel aus)'
$minLabel.Location = New-Object System.Drawing.Point(14, 27)
$minLabel.Size = New-Object System.Drawing.Size(230, 20)
$globalBox.Controls.Add($minLabel)

$minBattery = New-Object System.Windows.Forms.NumericUpDown
$minBattery.Location = New-Object System.Drawing.Point(256, 24)
$minBattery.Size = New-Object System.Drawing.Size(80, 22)
$minBattery.Minimum = 0
$minBattery.Maximum = 100
$minBattery.Value = [Math]::Max(0, [Math]::Min(100, [int]$GamingMinBatteryPercent))
$globalBox.Controls.Add($minBattery)

$autoSwitch = New-Object System.Windows.Forms.CheckBox
$autoSwitch.Text = 'Automatisch umschalten, wenn das Netzteil an-/abgesteckt wird'
$autoSwitch.Location = New-Object System.Drawing.Point(14, 54)
$autoSwitch.Size = New-Object System.Drawing.Size(380, 22)
try {
    if (Test-Path $SettingsFile) {
        $existingSettings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        $autoSwitch.Checked = [bool]$existingSettings.AutoSwitch
    }
} catch { }
$globalBox.Controls.Add($autoSwitch)

$form.Controls.Add($globalBox)
$y += 100

# --- Schaltflaechen ------------------------------------------------------
$hint = New-Object System.Windows.Forms.Label
$hint.Text = 'Aenderungen gelten ab dem naechsten Profilwechsel. Alles andere (Zeiten, WLAN, PCIe ...) steht weiterhin in Profiles.ps1.'
$hint.Location = New-Object System.Drawing.Point(14, $y)
$hint.Size = New-Object System.Drawing.Size(404, 34)
$hint.ForeColor = [System.Drawing.SystemColors]::GrayText
$form.Controls.Add($hint)
$y += 42

$btnDefaults = New-Object System.Windows.Forms.Button
$btnDefaults.Text = 'Standardwerte'
$btnDefaults.Location = New-Object System.Drawing.Point(12, $y)
$btnDefaults.Size = New-Object System.Drawing.Size(110, 28)
$form.Controls.Add($btnDefaults)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = 'Abbrechen'
$btnCancel.Location = New-Object System.Drawing.Point(218, $y)
$btnCancel.Size = New-Object System.Drawing.Size(96, 28)
$btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
$form.Controls.Add($btnCancel)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Speichern'
$btnSave.Location = New-Object System.Drawing.Point(322, $y)
$btnSave.Size = New-Object System.Drawing.Size(96, 28)
$btnSave.DialogResult = [System.Windows.Forms.DialogResult]::OK
$form.Controls.Add($btnSave)

$form.AcceptButton = $btnSave
$form.CancelButton = $btnCancel
$form.ClientSize = New-Object System.Drawing.Size(430, ($y + 44))

$btnDefaults.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Alle eigenen Anpassungen verwerfen und die mitgelieferten Vorgaben verwenden?',
        'Standardwerte', [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Remove-Item $OverrideFile -Force -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            'Die Vorgaben gelten ab dem naechsten Profilwechsel. Bitte das Fenster erneut oeffnen, um die Werte zu sehen.',
            'Standardwerte', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $form.Close()
    }
})

if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

# --- Speichern -----------------------------------------------------------
$overrides = @{ GamingMinBatteryPercent = [int]$minBattery.Value }

foreach ($key in 'Gaming', 'Balanced', 'Travel') {
    $c = $controls[$key]
    $entry = @{
        Brightness      = [int]$c.Brightness.Value
        Hertz           = [int]$c.Hertz.Value
        PauseBackground = [bool]$c.Throttle.Checked
    }
    if ($c.Cpu) {
        if ($c.CpuField -eq 'Ac') { $entry['CpuMaxAc'] = [int]$c.Cpu.Value } else { $entry['CpuMaxDc'] = [int]$c.Cpu.Value }
    }
    if ($c.Boost) { $entry[$c.BoostKey] = [int]$c.Boost.SelectedIndex }
    $overrides[$key] = $entry
}

try {
    [pscustomobject]$overrides | ConvertTo-Json -Depth 4 | Set-Content -Path $OverrideFile -Encoding UTF8
} catch {
    [System.Windows.Forms.MessageBox]::Show("Speichern fehlgeschlagen: $_", 'PowerProfile Switcher',
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    return
}

# Auto-Umschalten liegt in der Tray-Konfiguration
try {
    $traySettings = @{ AutoSwitch = [bool]$autoSwitch.Checked }
    if (Test-Path $SettingsFile) {
        $loaded = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        foreach ($prop in $loaded.PSObject.Properties) {
            if ($prop.Name -ne 'AutoSwitch') { $traySettings[$prop.Name] = $prop.Value }
        }
    }
    [pscustomobject]$traySettings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8
} catch { }

# Tray neu starten, damit die neuen Werte sofort greifen
try {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*Start-Tray.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-ScheduledTask -TaskName 'PowerProfileSwitcher-Tray' -ErrorAction SilentlyContinue
} catch { }

[System.Windows.Forms.MessageBox]::Show(
    'Gespeichert. Die Werte gelten ab dem naechsten Profilwechsel - waehle dazu einfach einmal dein Profil im Tray-Menue.',
    'PowerProfile Switcher', [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
