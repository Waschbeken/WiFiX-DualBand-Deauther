#Requires -Version 5.1
<#
    Show-PowerWindow.ps1

    Das Hauptfenster der App - Profile umschalten, alles einstellen und
    alle Werkzeuge starten, ohne Tray-Icon.

    Wichtig: Dieses Fenster laeuft nur, solange es offen ist. Schliesst du
    es, laeuft KEIN Prozess der App mehr im Hintergrund. Das ist der
    Unterschied zum Tray-Icon und der Grund, warum diese Variante mit
    Anti-Cheat-Systemen deutlich vertraeglicher ist.

    Braucht keine Administratorrechte - das Umschalten laeuft ueber die
    bei der Installation angelegten geplanten Aufgaben.
#>

$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ScriptDir    = $PSScriptRoot
$StateDir     = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$CurrentFile  = Join-Path $StateDir 'current.json'
$SettingsFile = Join-Path $StateDir 'settings.json'
$OverrideFile = Join-Path $StateDir 'profile-overrides.json'
$LogFile      = Join-Path $StateDir 'tray.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

. (Join-Path $ScriptDir 'Profiles.ps1')
. (Join-Path $ScriptDir 'PowerDisplay.ps1')

$MetricsScript    = Join-Path $ScriptDir 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

$TaskPrefix = 'PowerProfileSwitcher-'
$Invariant  = [System.Globalization.CultureInfo]::InvariantCulture

$Colors = @{
    Gaming   = [System.Drawing.Color]::FromArgb(230, 70, 50)
    Balanced = [System.Drawing.Color]::FromArgb(60, 130, 220)
    Travel   = [System.Drawing.Color]::FromArgb(60, 170, 90)
    Video    = [System.Drawing.Color]::FromArgb(150, 90, 200)
}
$Descriptions = @{
    Gaming   = 'Volle Leistung, hoechste Bildrate, dedizierte GPU an'
    Balanced = 'Windows-Standard, nichts wird verbogen'
    Travel   = 'Akku sparen: CPU gedrosselt, 60 Hz, nur integrierte Grafik'
    Video    = 'Bildschirm bleibt an, CPU sparsam ohne Turbo'
}

# --------------------------------------------------------------------------
# Hilfsfunktionen
# --------------------------------------------------------------------------

function Get-CurrentState {
    if (-not (Test-Path $CurrentFile)) { return $null }
    try { return (Get-Content $CurrentFile -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-CurrentMode {
    $state = Get-CurrentState
    if ($state) { return $state.Mode }
    return $null
}

function Load-Settings {
    $defaults = @{ AutoSwitch = $false; Hotkeys = $false }
    if (Test-Path $SettingsFile) {
        try {
            $loaded = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) { $defaults[$p.Name] = $p.Value }
        } catch { }
    }
    return $defaults
}

function Get-SettingValue {
    param($Definition, [string]$SettingName, [string]$Field, [int]$Fallback)
    foreach ($entry in $Definition.Settings) {
        if ($entry.Setting -contains $SettingName) { return [int]$entry[$Field] }
    }
    return $Fallback
}

function Start-Helper {
    param([string]$Script, [string[]]$Arguments = @())
    $path = Join-Path $ScriptDir $Script
    if (-not (Test-Path $path)) {
        [System.Windows.Forms.MessageBox]::Show(
            "$Script wurde nicht gefunden. Bitte Install.ps1 erneut ausfuehren.",
            'PowerProfile Switcher', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $all = @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$path`"") + $Arguments
    Start-Process powershell.exe -ArgumentList $all
}

function Invoke-Profile {
    param([string]$Name)
    try {
        Start-ScheduledTask -TaskName "$TaskPrefix$Name" -ErrorAction Stop
        $script:SwitchPending = 6      # naechste Sekunden haeufiger aktualisieren
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Konnte '$Name' nicht aktivieren - die geplante Aufgabe fehlt.`nBitte Install.ps1 als Administrator ausfuehren.",
            'PowerProfile Switcher', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
}

$Settings      = Load-Settings
$SwitchPending = 0
$DrawSamples   = @()

# --------------------------------------------------------------------------
# Fenster
# --------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = 'PowerProfile Switcher'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(700, 640)
$form.MinimumSize = New-Object System.Drawing.Size(700, 600)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point(14, 6)

$tabProfiles = New-Object System.Windows.Forms.TabPage
$tabProfiles.Text = 'Profile'
$tabProfiles.BackColor = [System.Drawing.SystemColors]::Control
$tabSettings = New-Object System.Windows.Forms.TabPage
$tabSettings.Text = 'Einstellungen'
$tabSettings.BackColor = [System.Drawing.SystemColors]::Control
$tabTools = New-Object System.Windows.Forms.TabPage
$tabTools.Text = 'Werkzeuge'
$tabTools.BackColor = [System.Drawing.SystemColors]::Control
$tabInfo = New-Object System.Windows.Forms.TabPage
$tabInfo.Text = 'Info'
$tabInfo.BackColor = [System.Drawing.SystemColors]::Control

[void]$tabs.TabPages.Add($tabProfiles)
[void]$tabs.TabPages.Add($tabSettings)
[void]$tabs.TabPages.Add($tabTools)
[void]$tabs.TabPages.Add($tabInfo)
$form.Controls.Add($tabs)

# --------------------------------------------------------------------------
# Reiter 1: Profile
# --------------------------------------------------------------------------

$statusBox = New-Object System.Windows.Forms.GroupBox
$statusBox.Text = 'Aktueller Zustand'
$statusBox.Location = New-Object System.Drawing.Point(16, 14)
$statusBox.Size = New-Object System.Drawing.Size(656, 104)

$lblProfile = New-Object System.Windows.Forms.Label
$lblProfile.Location = New-Object System.Drawing.Point(16, 26)
$lblProfile.Size = New-Object System.Drawing.Size(620, 26)
$lblProfile.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$lblProfile.Text = 'Wird geladen ...'
$statusBox.Controls.Add($lblProfile)

$lblPower = New-Object System.Windows.Forms.Label
$lblPower.Location = New-Object System.Drawing.Point(16, 54)
$lblPower.Size = New-Object System.Drawing.Size(620, 20)
$lblPower.Text = ''
$statusBox.Controls.Add($lblPower)

$lblSystem = New-Object System.Windows.Forms.Label
$lblSystem.Location = New-Object System.Drawing.Point(16, 74)
$lblSystem.Size = New-Object System.Drawing.Size(620, 20)
$lblSystem.ForeColor = [System.Drawing.SystemColors]::GrayText
$lblSystem.Text = ''
$statusBox.Controls.Add($lblSystem)

$tabProfiles.Controls.Add($statusBox)

# --- Profil-Kacheln (2 x 2) ---
$tiles = @{}
$tileKeys = @('Gaming', 'Balanced', 'Travel', 'Video')
for ($i = 0; $i -lt $tileKeys.Count; $i++) {
    $key = $tileKeys[$i]
    $def = $ProfileDefinitions[$key]
    if (-not $def) { continue }

    $col = $i % 2
    $row = [Math]::Floor($i / 2)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Point((16 + $col * 336), (132 + $row * 104))
    $btn.Size = New-Object System.Drawing.Size(320, 92)
    $btn.TextAlign = 'MiddleLeft'
    $btn.FlatStyle = 'Flat'
    $btn.FlatAppearance.BorderSize = 2
    $btn.FlatAppearance.BorderColor = [System.Drawing.SystemColors]::ControlDark
    $btn.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $btn.Padding = New-Object System.Windows.Forms.Padding(12, 0, 8, 0)
    $btn.Text = "$($def.DisplayName)`n$($Descriptions[$key])"
    $btn.Tag = $key
    $btn.Add_Click({ Invoke-Profile -Name $this.Tag })
    $tabProfiles.Controls.Add($btn)
    $tiles[$key] = $btn
}

$btnBack = New-Object System.Windows.Forms.Button
$btnBack.Location = New-Object System.Drawing.Point(16, 348)
$btnBack.Size = New-Object System.Drawing.Size(320, 30)
$btnBack.Text = 'Zurueck zum vorherigen Profil'
$btnBack.Add_Click({
    $state = Get-CurrentState
    if ($state -and $state.Previous) { Invoke-Profile -Name $state.Previous }
})
$tabProfiles.Controls.Add($btnBack)

$btnStatus = New-Object System.Windows.Forms.Button
$btnStatus.Location = New-Object System.Drawing.Point(352, 348)
$btnStatus.Size = New-Object System.Drawing.Size(320, 30)
$btnStatus.Text = 'Systemzustand & Vorschau anzeigen'
$btnStatus.Add_Click({ Start-Helper -Script 'Show-PowerStatus.ps1' })
$tabProfiles.Controls.Add($btnStatus)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Location = New-Object System.Drawing.Point(16, 392)
$lblHint.Size = New-Object System.Drawing.Size(656, 60)
$lblHint.ForeColor = [System.Drawing.SystemColors]::GrayText
$lblHint.Text = "Solange dieses Fenster offen ist, laeuft ein Prozess der App - danach nicht mehr." + [Environment]::NewLine +
                "Zum Spielen also: Profil waehlen, Fenster schliessen, Spiel starten. Die Einstellungen" + [Environment]::NewLine +
                "bleiben aktiv, weil sie in Windows selbst gespeichert sind."
$tabProfiles.Controls.Add($lblHint)

# --------------------------------------------------------------------------
# Reiter 2: Einstellungen
# --------------------------------------------------------------------------

$lblPick = New-Object System.Windows.Forms.Label
$lblPick.Location = New-Object System.Drawing.Point(16, 18)
$lblPick.Size = New-Object System.Drawing.Size(120, 20)
$lblPick.Text = 'Profil bearbeiten:'
$tabSettings.Controls.Add($lblPick)

$cmbProfile = New-Object System.Windows.Forms.ComboBox
$cmbProfile.Location = New-Object System.Drawing.Point(140, 15)
$cmbProfile.Size = New-Object System.Drawing.Size(240, 22)
$cmbProfile.DropDownStyle = 'DropDownList'
foreach ($key in $tileKeys) {
    if ($ProfileDefinitions[$key]) { [void]$cmbProfile.Items.Add($ProfileDefinitions[$key].DisplayName) }
}
$cmbProfile.SelectedIndex = 0
$tabSettings.Controls.Add($cmbProfile)

$profileBox = New-Object System.Windows.Forms.GroupBox
$profileBox.Text = 'Werte fuer dieses Profil'
$profileBox.Location = New-Object System.Drawing.Point(16, 48)
$profileBox.Size = New-Object System.Drawing.Size(656, 176)
$tabSettings.Controls.Add($profileBox)

function New-SettingLabel {
    param([string]$Text, [int]$Top)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point(16, ($Top + 3))
    $l.Size = New-Object System.Drawing.Size(300, 20)
    return $l
}
function New-SettingNumber {
    param([int]$Top, [int]$Min, [int]$Max)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Location = New-Object System.Drawing.Point(330, $Top)
    $n.Size = New-Object System.Drawing.Size(90, 22)
    $n.Minimum = $Min
    $n.Maximum = $Max
    return $n
}

$profileBox.Controls.Add((New-SettingLabel -Text 'Bildschirmhelligkeit (%)' -Top 26))
$numBrightness = New-SettingNumber -Top 26 -Min 0 -Max 100
$profileBox.Controls.Add($numBrightness)

$profileBox.Controls.Add((New-SettingLabel -Text 'Bildwiederholrate (Hz, 0 = nicht aendern)' -Top 54))
$numHertz = New-SettingNumber -Top 54 -Min 0 -Max 480
$profileBox.Controls.Add($numHertz)

$profileBox.Controls.Add((New-SettingLabel -Text 'CPU-Maximum im Akkubetrieb (%)' -Top 82))
$numCpu = New-SettingNumber -Top 82 -Min 20 -Max 100
$profileBox.Controls.Add($numCpu)

$profileBox.Controls.Add((New-SettingLabel -Text 'Turbo/Boost im Akkubetrieb' -Top 110))
$cmbBoost = New-Object System.Windows.Forms.ComboBox
$cmbBoost.Location = New-Object System.Drawing.Point(330, 110)
$cmbBoost.Size = New-Object System.Drawing.Size(140, 22)
$cmbBoost.DropDownStyle = 'DropDownList'
[void]$cmbBoost.Items.AddRange(@('Aus', 'Ein', 'Aggressiv'))
$profileBox.Controls.Add($cmbBoost)

$chkThrottle = New-Object System.Windows.Forms.CheckBox
$chkThrottle.Text = 'Hintergrund-Dienste bremsen (Suchindizierung, Update-Auslieferung)'
$chkThrottle.Location = New-Object System.Drawing.Point(16, 142)
$chkThrottle.Size = New-Object System.Drawing.Size(620, 22)
$profileBox.Controls.Add($chkThrottle)

$globalBox = New-Object System.Windows.Forms.GroupBox
$globalBox.Text = 'Allgemein'
$globalBox.Location = New-Object System.Drawing.Point(16, 236)
$globalBox.Size = New-Object System.Drawing.Size(656, 150)

$globalBox.Controls.Add((New-SettingLabel -Text 'Gaming erst ab Akkustand (%, 0 = Regel aus)' -Top 26))
$numMinBattery = New-SettingNumber -Top 26 -Min 0 -Max 100
$numMinBattery.Value = [Math]::Max(0, [Math]::Min(100, [int]$GamingMinBatteryPercent))
$globalBox.Controls.Add($numMinBattery)

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = 'Automatisch umschalten, wenn das Netzteil an-/abgesteckt wird (nur mit Tray-Icon)'
$chkAuto.Location = New-Object System.Drawing.Point(16, 58)
$chkAuto.Size = New-Object System.Drawing.Size(620, 22)
$chkAuto.Checked = [bool]$Settings.AutoSwitch
$globalBox.Controls.Add($chkAuto)

$chkHotkeys = New-Object System.Windows.Forms.CheckBox
$chkHotkeys.Text = 'Globale Hotkeys Strg+Alt+1..4 (nur mit Tray-Icon; kann Anti-Cheat stoeren)'
$chkHotkeys.Location = New-Object System.Drawing.Point(16, 84)
$chkHotkeys.Size = New-Object System.Drawing.Size(620, 22)
$chkHotkeys.Checked = [bool]$Settings.Hotkeys
$globalBox.Controls.Add($chkHotkeys)

$lblSaveHint = New-Object System.Windows.Forms.Label
$lblSaveHint.Location = New-Object System.Drawing.Point(16, 112)
$lblSaveHint.Size = New-Object System.Drawing.Size(620, 30)
$lblSaveHint.ForeColor = [System.Drawing.SystemColors]::GrayText
$lblSaveHint.Text = 'Gespeicherte Werte gelten ab dem naechsten Profilwechsel. Alles Weitere (Zeiten, WLAN, PCIe) steht in Profiles.ps1.'
$globalBox.Controls.Add($lblSaveHint)

$tabSettings.Controls.Add($globalBox)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Location = New-Object System.Drawing.Point(552, 398)
$btnSave.Size = New-Object System.Drawing.Size(120, 30)
$btnSave.Text = 'Speichern'
$tabSettings.Controls.Add($btnSave)

$btnDefaults = New-Object System.Windows.Forms.Button
$btnDefaults.Location = New-Object System.Drawing.Point(16, 398)
$btnDefaults.Size = New-Object System.Drawing.Size(160, 30)
$btnDefaults.Text = 'Standardwerte'
$tabSettings.Controls.Add($btnDefaults)

# Anpassungen werden im Fenster gehalten und erst beim Speichern geschrieben.
$Pending = @{}
foreach ($key in $tileKeys) { $Pending[$key] = @{} }

function Get-SelectedKey {
    $index = $cmbProfile.SelectedIndex
    if ($index -lt 0 -or $index -ge $tileKeys.Count) { return $tileKeys[0] }
    return $tileKeys[$index]
}

function Load-ProfileFields {
    $key = Get-SelectedKey
    $def = $ProfileDefinitions[$key]
    if (-not $def) { return }

    $entry = $Pending[$key]

    $brightness = if ($entry.ContainsKey('Brightness')) { $entry.Brightness } else { [int]$def.Brightness }
    $hertz      = if ($entry.ContainsKey('Hertz'))      { $entry.Hertz }      else { [int]$def.Hertz }
    $cpu        = if ($entry.ContainsKey('CpuMaxDc'))   { $entry.CpuMaxDc }   else { Get-SettingValue $def 'PROCTHROTTLEMAX' 'Dc' 100 }
    $boost      = if ($entry.ContainsKey('BoostDc'))    { $entry.BoostDc }    else { Get-SettingValue $def 'PERFBOOSTMODE' 'Dc' 1 }
    $throttle   = if ($entry.ContainsKey('PauseBackground')) { [bool]$entry.PauseBackground } else { [bool]$def.PauseBackground }

    $numBrightness.Value = [Math]::Max(0, [Math]::Min(100, $brightness))
    $numHertz.Value      = [Math]::Max(0, [Math]::Min(480, $hertz))
    $numCpu.Value        = [Math]::Max(20, [Math]::Min(100, $cpu))
    if ($boost -lt 0 -or $boost -gt 2) { $boost = 1 }
    $cmbBoost.SelectedIndex = $boost
    $chkThrottle.Checked = $throttle

    # Das Standardschema hat bewusst keine eigenen CPU-Werte.
    $hasOwnValues = -not $def.UseBaseDirectly
    $numCpu.Enabled = $hasOwnValues
    $cmbBoost.Enabled = $hasOwnValues
}

function Save-ProfileFields {
    $key = Get-SelectedKey
    $def = $ProfileDefinitions[$key]
    if (-not $def) { return }

    $entry = $Pending[$key]
    $entry['Brightness']      = [int]$numBrightness.Value
    $entry['Hertz']           = [int]$numHertz.Value
    $entry['PauseBackground'] = [bool]$chkThrottle.Checked
    if (-not $def.UseBaseDirectly) {
        $entry['CpuMaxDc'] = [int]$numCpu.Value
        $entry['BoostDc']  = [int]$cmbBoost.SelectedIndex
    }
}

$cmbProfile.Add_SelectedIndexChanged({
    if ($script:LastSelectedKey) {
        $current = Get-SelectedKey
        if ($current -ne $script:LastSelectedKey) {
            # Werte des vorher gewaehlten Profils uebernehmen
            $index = [Array]::IndexOf($tileKeys, $script:LastSelectedKey)
            if ($index -ge 0) {
                $keep = $cmbProfile.SelectedIndex
                $cmbProfile.SelectedIndex = $index
                Save-ProfileFields
                $cmbProfile.SelectedIndex = $keep
            }
        }
    }
    $script:LastSelectedKey = Get-SelectedKey
    Load-ProfileFields
})
$LastSelectedKey = Get-SelectedKey
Load-ProfileFields

$btnSave.Add_Click({
    Save-ProfileFields

    try {
        $overrides = @{}
        if (Test-Path $OverrideFile) {
            $existing = Get-Content $OverrideFile -Raw | ConvertFrom-Json
            foreach ($prop in $existing.PSObject.Properties) { $overrides[$prop.Name] = $prop.Value }
        }
        $overrides['GamingMinBatteryPercent'] = [int]$numMinBattery.Value

        foreach ($key in $tileKeys) {
            if ($Pending[$key].Count -eq 0) { continue }
            $merged = @{}
            if ($overrides.ContainsKey($key) -and $overrides[$key]) {
                foreach ($prop in $overrides[$key].PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
            }
            foreach ($name in $Pending[$key].Keys) { $merged[$name] = $Pending[$key][$name] }
            $overrides[$key] = [pscustomobject]$merged
        }

        [pscustomobject]$overrides | ConvertTo-Json -Depth 4 | Set-Content -Path $OverrideFile -Encoding UTF8

        $traySettings = @{ AutoSwitch = [bool]$chkAuto.Checked; Hotkeys = [bool]$chkHotkeys.Checked }
        if (Test-Path $SettingsFile) {
            $loaded = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            foreach ($prop in $loaded.PSObject.Properties) {
                if ($prop.Name -notin @('AutoSwitch', 'Hotkeys')) { $traySettings[$prop.Name] = $prop.Value }
            }
        }
        [pscustomobject]$traySettings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8

        [System.Windows.Forms.MessageBox]::Show(
            'Gespeichert. Die Werte gelten ab dem naechsten Profilwechsel - waehle dazu einfach einmal dein Profil.',
            'PowerProfile Switcher', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Speichern fehlgeschlagen: $_", 'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnDefaults.Add_Click({
    $answer = [System.Windows.Forms.MessageBox]::Show(
        'Alle eigenen Anpassungen verwerfen und die mitgelieferten Vorgaben verwenden?',
        'Standardwerte', [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
        Remove-Item $OverrideFile -Force -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            'Zurueckgesetzt. Bitte das Fenster schliessen und neu oeffnen, um die Vorgaben zu sehen.',
            'PowerProfile Switcher', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
})

# --------------------------------------------------------------------------
# Reiter 3: Werkzeuge
# --------------------------------------------------------------------------

$toolDefs = @(
    @{ Text = 'Verbrauchs-Bericht anzeigen';        Script = 'New-PowerReport.ps1';        Args = @();                      Info = 'Diagramm und Durchschnittswerte aus dem Protokoll' }
    @{ Text = 'Diagnose ausfuehren';                Script = 'Test-PowerProfile.ps1';      Args = @();                      Info = 'Prueft, welche Einstellungen dein Geraet wirklich annimmt' }
    @{ Text = 'Leistungstest fuer dieses Profil';   Script = 'Test-PowerPerformance.ps1';  Args = @();                      Info = 'Misst Leistung und Verbrauch des aktiven Profils' }
    @{ Text = 'CPU-Grenze kalibrieren';             Script = 'Invoke-PowerCalibration.ps1';Args = @();                      Info = 'Sucht im Akkubetrieb den effizientesten Wert' }
    @{ Text = 'Einrichtung (Hardware erkennen)';    Script = 'Start-PowerSetup.ps1';       Args = @();                      Info = 'Liest Panel, GPU und Akku aus und schlaegt Werte vor' }
    @{ Text = 'Konfiguration sichern';              Script = 'Backup-PowerConfig.ps1';     Args = @('-Action', 'Export');   Info = 'Einstellungen und Messdaten in eine ZIP-Datei' }
    @{ Text = 'Konfiguration wiederherstellen';     Script = 'Backup-PowerConfig.ps1';     Args = @('-Action', 'Import');   Info = 'Sicherung wieder einspielen' }
    @{ Text = 'Alles zuruecksetzen (Notfall)';      Script = 'Reset-PowerProfile.ps1';     Args = @();                      Info = 'GPU an, Dienste zurueck, Standardschema, Helligkeit und Hz' }
    @{ Text = 'Nach Updates suchen';                Script = 'Update-PowerProfile.ps1';    Args = @();                      Info = 'Holt die neueste Fassung aus dem Repository' }
)

$toolY = 16
foreach ($tool in $toolDefs) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point(16, $toolY)
    $b.Size = New-Object System.Drawing.Size(260, 30)
    $b.Text = $tool.Text
    $b.Tag = $tool
    $b.Add_Click({ Start-Helper -Script $this.Tag.Script -Arguments $this.Tag.Args })
    $tabTools.Controls.Add($b)

    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object System.Drawing.Point(288, ($toolY + 7))
    $l.Size = New-Object System.Drawing.Size(384, 20)
    $l.ForeColor = [System.Drawing.SystemColors]::GrayText
    $l.Text = $tool.Info
    $tabTools.Controls.Add($l)

    $toolY += 38
}

$bgBox = New-Object System.Windows.Forms.GroupBox
$bgBox.Text = 'Hintergrunddienst (Tray-Icon)'
$bgBox.Location = New-Object System.Drawing.Point(16, ($toolY + 8))
$bgBox.Size = New-Object System.Drawing.Size(656, 116)

$lblBg = New-Object System.Windows.Forms.Label
$lblBg.Location = New-Object System.Drawing.Point(16, 24)
$lblBg.Size = New-Object System.Drawing.Size(624, 44)
$lblBg.Text = "Das Tray-Icon ist ein dauerhaft laufender, versteckter Prozess - nur damit gibt es Watt-Anzeige," + [Environment]::NewLine +
              "Protokoll, Standby-Auswertung und automatisches Umschalten. Anti-Cheat-Systeme moegen so etwas nicht."
$bgBox.Controls.Add($lblBg)

$btnBgOff = New-Object System.Windows.Forms.Button
$btnBgOff.Location = New-Object System.Drawing.Point(16, 72)
$btnBgOff.Size = New-Object System.Drawing.Size(260, 30)
$btnBgOff.Text = 'Hintergrunddienst abschalten'
$btnBgOff.Add_Click({ Start-Helper -Script 'Set-PowerBackground.ps1' -Arguments @('-Action', 'Disable') })
$bgBox.Controls.Add($btnBgOff)

$btnBgOn = New-Object System.Windows.Forms.Button
$btnBgOn.Location = New-Object System.Drawing.Point(288, 72)
$btnBgOn.Size = New-Object System.Drawing.Size(260, 30)
$btnBgOn.Text = 'Hintergrunddienst einschalten'
$btnBgOn.Add_Click({ Start-Helper -Script 'Set-PowerBackground.ps1' -Arguments @('-Action', 'Enable') })
$bgBox.Controls.Add($btnBgOn)

$tabTools.Controls.Add($bgBox)

# --------------------------------------------------------------------------
# Reiter 4: Info
# --------------------------------------------------------------------------

$infoText = New-Object System.Windows.Forms.TextBox
$infoText.Multiline = $true
$infoText.ReadOnly = $true
$infoText.ScrollBars = 'Vertical'
$infoText.Location = New-Object System.Drawing.Point(16, 16)
$infoText.Size = New-Object System.Drawing.Size(656, 500)
$infoText.Font = New-Object System.Drawing.Font('Consolas', 9)

$infoLines = @()
$infoLines += "PowerProfile Switcher $PowerProfileVersion"
$infoLines += ''
$infoLines += "Programmordner : $ScriptDir"
$infoLines += "Daten          : $StateDir"
$infoLines += ''
$infoLines += 'Dieses Fenster laeuft nur, solange es offen ist. Wenn du es schliesst,'
$infoLines += 'bleibt kein Prozess der App zurueck - die Energieprofile bleiben trotzdem'
$infoLines += 'aktiv, weil sie als Windows-Energieschemata gespeichert sind.'
$infoLines += ''
$infoLines += 'Profile umschalten geht ausserdem ueber die Verknuepfungen auf dem Desktop'
$infoLines += 'und im Startmenue - dabei laeuft nur fuer wenige Sekunden etwas.'
$infoLines += ''
$infoLines += 'Was die App aendert: Windows-Energieschemata (powercfg), Bildschirmhelligkeit,'
$infoLines += 'Bildwiederholrate, im Unterwegs-Profil die dedizierte GPU und optional zwei'
$infoLines += 'Hintergrunddienste. Luefter, RGB und Akku-Ladelimit bleiben dem XMG Control'
$infoLines += 'Center vorbehalten.'
$infoText.Text = ($infoLines -join "`r`n")
$tabInfo.Controls.Add($infoText)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Location = New-Object System.Drawing.Point(16, 528)
$btnLog.Size = New-Object System.Drawing.Size(200, 30)
$btnLog.Text = 'Protokoll oeffnen'
$btnLog.Add_Click({
    if (Test-Path $LogFile) { Start-Process notepad.exe -ArgumentList "`"$LogFile`"" }
    else {
        [System.Windows.Forms.MessageBox]::Show('Es gibt noch kein Protokoll.', 'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
})
$tabInfo.Controls.Add($btnLog)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Location = New-Object System.Drawing.Point(228, 528)
$btnFolder.Size = New-Object System.Drawing.Size(200, 30)
$btnFolder.Text = 'Datenordner oeffnen'
$btnFolder.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$StateDir`"" })
$tabInfo.Controls.Add($btnFolder)

# --------------------------------------------------------------------------
# Laufende Aktualisierung (nur solange das Fenster offen ist)
# --------------------------------------------------------------------------

function Update-Status {
    $mode = Get-CurrentMode

    foreach ($key in $tiles.Keys) {
        $btn = $tiles[$key]
        if ($key -eq $mode) {
            $btn.BackColor = $Colors[$key]
            $btn.ForeColor = [System.Drawing.Color]::White
            $btn.FlatAppearance.BorderColor = $Colors[$key]
        } else {
            $btn.BackColor = [System.Drawing.SystemColors]::Control
            $btn.ForeColor = [System.Drawing.SystemColors]::ControlText
            $btn.FlatAppearance.BorderColor = [System.Drawing.SystemColors]::ControlDark
        }
    }

    if ($mode -and $ProfileDefinitions[$mode]) {
        $lblProfile.Text = $ProfileDefinitions[$mode].DisplayName
        $lblProfile.ForeColor = $Colors[$mode]
    } else {
        $lblProfile.Text = 'Noch kein Profil gewaehlt'
        $lblProfile.ForeColor = [System.Drawing.SystemColors]::ControlText
    }

    $state = Get-CurrentState
    $btnBack.Enabled = ($state -and $state.Previous)
    if ($state -and $state.Previous -and $ProfileDefinitions[$state.Previous]) {
        $btnBack.Text = "Zurueck zu $($ProfileDefinitions[$state.Previous].DisplayName)"
    } else {
        $btnBack.Text = 'Zurueck zum vorherigen Profil'
    }

    # Akku und Verbrauch
    $reading = $null
    if ($MetricsAvailable) { $reading = Get-BatteryReading }

    if (-not $reading) {
        $lblPower.Text = 'Kein Akku erkannt'
    } elseif ($reading.OnAc -and $reading.DrawWatt -le 0) {
        $script:DrawSamples = @()
        $lblPower.Text = "Am Netzteil - Akku $($reading.Percent) %"
    } else {
        if ($reading.DrawWatt -gt 0) {
            $script:DrawSamples += $reading.DrawWatt
            if ($script:DrawSamples.Count -gt 8) {
                $script:DrawSamples = @($script:DrawSamples | Select-Object -Last 8)
            }
        }
        if ($script:DrawSamples.Count -gt 0) {
            $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
            $rest = Format-Duration -Hours ($reading.RemainingWh / $avg)
            $lblPower.Text = ('{0:N1} W - Akku {1} %, noch ca. {2}' -f $avg, $reading.Percent, $rest)
        } else {
            $lblPower.Text = "Akku $($reading.Percent) % - Verbrauch wird gemessen ..."
        }
    }

    # Anzeige und GPU
    $parts = @()
    $hz = Get-CurrentDisplayRate
    if ($hz -gt 0) { $parts += "$hz Hz" }
    try {
        $gpu = Get-PnpDevice -Class Display -PresentOnly -ErrorAction Stop |
               Where-Object { $_.FriendlyName -match 'NVIDIA|Radeon RX|Radeon Pro|Radeon\s*\d{3,4}' } |
               Select-Object -First 1
        if ($gpu) {
            $parts += $(if ($gpu.Status -eq 'OK') { 'dedizierte GPU aktiv' } else { 'dedizierte GPU deaktiviert' })
        }
    } catch { }
    $lblSystem.Text = ($parts -join '   |   ')
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({
    if ($script:SwitchPending -gt 0) { $script:SwitchPending-- }
    Update-Status
})
$timer.Start()

$form.Add_FormClosed({
    try { $timer.Stop(); $timer.Dispose() } catch { }
})

Update-Status
[void]$form.ShowDialog()
