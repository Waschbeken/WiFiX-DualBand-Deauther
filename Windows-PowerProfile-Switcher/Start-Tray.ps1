#Requires -Version 5.1
<#
    Start-Tray.ps1

    Symbol im Windows-Infobereich (Tray) mit Menue zum sofortigen
    Umschalten der Energieprofile. Laeuft OHNE Administratorrechte und
    loest nur die per Install.ps1 angelegten geplanten Aufgaben aus, die
    bereits erhoehte Rechte haben - daher kein UAC-Fenster beim Umschalten.

    Funktionen:
      - Umschalten per Menue oder Hotkey (Strg+Alt+1/2/3)
      - Live-Anzeige von Verbrauch (W) und Restlaufzeit
      - Protokolliert die Messwerte, um echte Durchschnittswerte je Profil
        zu bilden (power-log.csv)
      - Optionales automatisches Umschalten beim An-/Abstecken des Netzteils
      - Warnung bei 20 % / 10 % Akku mit geschaetzter Restlaufzeit
      - Diagnose-Bericht (Test-PowerProfile.ps1)

    Das Icon haelt sich selbst am Leben: ein Timer setzt regelmaessig
    "Visible = true" erneut, falls Windows das Icon nach einem
    Grafiktreiber-Reset oder einem Explorer-Neustart entfernt hat.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ScriptDir   = $PSScriptRoot
$TaskPrefix  = 'PowerProfileSwitcher-'
$StateDir    = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$CurrentFile = Join-Path $StateDir 'current.json'
$SettingsFile= Join-Path $StateDir 'settings.json'
$LogCsv      = Join-Path $StateDir 'power-log.csv'
$LogFile     = Join-Path $StateDir 'tray.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# Funktionen zur Verbrauchsmessung einbinden (Watt / Restlaufzeit).
$MetricsScript    = Join-Path $ScriptDir 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

# Profil-Definitionen einbinden (u.a. Mindest-Akku fuer das Gaming-Profil).
$GamingMinBatteryPercent = 40
$ProfilesScript = Join-Path $ScriptDir 'Profiles.ps1'
if (Test-Path $ProfilesScript) { . $ProfilesScript }

# Ein einzelner Fehler in einem Menü-/Timer-Handler soll das Tray-Icon
# nicht abstuerzen lassen - nur protokollieren und weiterlaufen.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $($e.Exception)" | Add-Content -Path $LogFile -Encoding UTF8
    } catch {}
})

function E {
    param([int]$CodePoint)
    try { [char]::ConvertFromUtf32($CodePoint) } catch { '' }
}

function Get-CurrentMode {
    if (-not (Test-Path $CurrentFile)) { return $null }
    try { return (Get-Content $CurrentFile -Raw | ConvertFrom-Json).Mode } catch { return $null }
}

# --- Einstellungen (persistent) -----------------------------------------
function Load-Settings {
    $defaults = @{ AutoSwitch = $false }
    if (Test-Path $SettingsFile) {
        try {
            $loaded = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $loaded.PSObject.Properties) { $defaults[$p.Name] = $p.Value }
        } catch { }
    }
    return $defaults
}

function Save-Settings {
    try { [pscustomobject]$Settings | ConvertTo-Json | Set-Content -Path $SettingsFile -Encoding UTF8 } catch { }
}

$Settings = Load-Settings

# --- Farbige Punkt-Icons je Profil erzeugen (kein externes .ico noetig) ---
function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush $Color
        $g.FillEllipse($brush, 2, 2, 28, 28)
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
        $g.DrawEllipse($pen, 2, 2, 28, 28)
        return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } finally {
        $g.Dispose()
        $bmp.Dispose()
    }
}

$Icons = @{
    Gaming   = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(230, 70, 50))
    Balanced = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(60, 130, 220))
    Travel   = New-DotIcon -Color ([System.Drawing.Color]::FromArgb(60, 170, 90))
    Unknown  = [System.Drawing.SystemIcons]::Information
}

$Labels = @{
    Gaming   = 'Gaming (Hoechstleistung)'
    Balanced = 'Ausgeglichen'
    Travel   = 'Unterwegs (Akku sparen)'
}

$ShortLabels = @{
    Gaming   = 'Gaming'
    Balanced = 'Ausgeglichen'
    Travel   = 'Unterwegs'
}

# Gleitender Mittelwert der letzten Messpunkte fuer die Live-Anzeige.
$DrawSamples    = @()
$MaxDrawSamples = 8
$LastOnAc       = $null
$WarnedLevels   = @()
$PendingGaming  = $false   # Gaming beim Anstecken gewuenscht, aber Akku noch zu leer

function Invoke-Profile {
    param(
        [string]$Name,
        [string]$TaskSuffix = ''
    )
    $taskName = "$TaskPrefix$Name$TaskSuffix"
    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $script:PendingGaming = $false
        $script:DrawSamples = @()   # alte Messwerte gelten fuer das alte Profil
        $script:kickTimer.Stop()
        $script:kickTimer.Start()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Konnte Profil '$Name' nicht aktivieren (Aufgabe '$taskName' fehlt).`nBitte Install.ps1 als Administrator ausfuehren.",
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

# --- Messwerte protokollieren (fuer Langzeit-Durchschnitt) ---------------
function Write-PowerLog {
    param($Reading, [string]$ModeName)
    if (-not $Reading -or $Reading.DrawWatt -le 0) { return }
    try {
        if (-not (Test-Path $LogCsv)) {
            'Zeit;Profil;Watt;Prozent' | Set-Content -Path $LogCsv -Encoding UTF8
        } elseif ((Get-Item $LogCsv).Length -gt 2MB) {
            # Protokoll kurz halten: nur die juengsten Zeilen behalten
            $keep = Get-Content $LogCsv -Tail 8000
            'Zeit;Profil;Watt;Prozent' | Set-Content -Path $LogCsv -Encoding UTF8
            $keep | Where-Object { $_ -notlike 'Zeit;*' } | Add-Content -Path $LogCsv -Encoding UTF8
        }

        $line = '{0};{1};{2};{3}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
            $(if ($ModeName) { $ModeName } else { 'unbekannt' }),
            $Reading.DrawWatt.ToString($Invariant),
            $Reading.Percent
        $line | Add-Content -Path $LogCsv -Encoding UTF8
    } catch { }
}

# Durchschnittsverbrauch je Profil ueber das gesamte Protokoll.
function Get-LogStatistics {
    if (-not (Test-Path $LogCsv)) { return @() }
    try {
        $rows = Import-Csv -Path $LogCsv -Delimiter ';'
    } catch { return @() }
    if (-not $rows) { return @() }

    $result = @()
    foreach ($group in ($rows | Group-Object Profil)) {
        $watts = @()
        foreach ($row in $group.Group) {
            try { $watts += [double]::Parse($row.Watt, $Invariant) } catch { }
        }
        if ($watts.Count -eq 0) { continue }
        $result += [pscustomobject]@{
            Profil = $group.Name
            Watt   = [Math]::Round((($watts | Measure-Object -Average).Average), 1)
            Anzahl = $watts.Count
        }
    }
    return $result
}

# Liest den Akku aus, pflegt den gleitenden Mittelwert und liefert kurze
# Texte fuer Menue und Tooltip.
function Get-PowerStatusText {
    param($Reading)
    if (-not $MetricsAvailable) { return @{ Menu = 'Verbrauchsmessung nicht verfuegbar'; Tip = '' } }
    if (-not $Reading) { return @{ Menu = 'Kein Akku erkannt'; Tip = '' } }

    if ($Reading.DrawWatt -gt 0) {
        $script:DrawSamples += $Reading.DrawWatt
        if ($script:DrawSamples.Count -gt $MaxDrawSamples) {
            $script:DrawSamples = @($script:DrawSamples | Select-Object -Last $MaxDrawSamples)
        }
    } elseif ($Reading.OnAc) {
        $script:DrawSamples = @()
    }

    if ($script:DrawSamples.Count -eq 0) {
        if ($Reading.OnAc) {
            return @{ Menu = "Am Netzteil - Akku $($Reading.Percent) %"; Tip = "Netz - $($Reading.Percent) %" }
        }
        return @{ Menu = "Akku $($Reading.Percent) % - Verbrauch wird gemessen ..."; Tip = "$($Reading.Percent) %" }
    }

    $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
    $rest = Format-Duration -Hours ($Reading.RemainingWh / $avg)

    return @{
        Menu = ('{0:N1} W - Akku {1} %, noch ca. {2}' -f $avg, $Reading.Percent, $rest)
        Tip  = ('{0:N1} W, ~{1}' -f $avg, $rest)
    }
}

function Show-Balloon {
    param([string]$Title, [string]$Text)
    try {
        $notifyIcon.BalloonTipTitle = $Title
        $notifyIcon.BalloonTipText  = $Text
        $notifyIcon.ShowBalloonTip(6000)
    } catch { }
}

# Gaming ist erst ab einem Mindest-Ladestand erlaubt. Ohne verlaessliche
# Akku-Werte (z.B. Desktop-PC) gilt die Regel nicht.
function Test-GamingAllowed {
    param($Reading)
    if ($GamingMinBatteryPercent -le 0) { return $true }
    if (-not $Reading) { return $true }
    if ($Reading.FullWh -le 0 -or $Reading.Percent -le 0) { return $true }
    return ($Reading.Percent -ge $GamingMinBatteryPercent)
}

# --- Automatisches Umschalten beim An-/Abstecken -------------------------
function Invoke-AutoSwitch {
    param($Reading)
    if (-not $Reading) { return }

    $previous = $script:LastOnAc
    $script:LastOnAc = $Reading.OnAc

    if (-not $Settings.AutoSwitch) {
        $script:PendingGaming = $false
        return
    }

    $changed = ($null -ne $previous -and $previous -ne $Reading.OnAc)
    $current = Get-CurrentMode

    if (-not $Reading.OnAc) {
        $script:PendingGaming = $false
        if ($changed -and $current -ne 'Travel') {
            # Ohne GPU-Umschaltung, damit beim Ausstecken keine Neustart-Abfrage kommt.
            Invoke-Profile -Name 'Travel' -TaskSuffix '-NoGpu'
            Show-Balloon -Title 'Netzteil getrennt' -Text 'Automatisch auf Unterwegs (Akku sparen) umgeschaltet. Die dedizierte GPU bleibt an - zum Abschalten das Profil einmal von Hand waehlen.'
        }
        return
    }

    # Netzbetrieb: beim Anstecken Gaming vormerken ...
    if ($changed -and $current -ne 'Gaming') {
        $script:PendingGaming = $true
        if (-not (Test-GamingAllowed -Reading $Reading)) {
            Show-Balloon -Title 'Netzteil angeschlossen' `
                -Text ("Akku bei {0} % - Gaming folgt automatisch, sobald {1} % erreicht sind." -f $Reading.Percent, $GamingMinBatteryPercent)
        }
    }

    # ... und erst aktivieren, wenn der Akku weit genug geladen ist.
    if ($script:PendingGaming -and (Test-GamingAllowed -Reading $Reading)) {
        $script:PendingGaming = $false
        if ($current -ne 'Gaming') {
            Invoke-Profile -Name 'Gaming'
            Show-Balloon -Title 'Netzteil angeschlossen' -Text 'Automatisch auf Gaming (Hoechstleistung) umgeschaltet.'
        }
    }
}

# --- Akku-Warnungen ------------------------------------------------------
function Test-BatteryWarning {
    param($Reading)
    if (-not $Reading) { return }

    if ($Reading.OnAc) {
        $script:WarnedLevels = @()
        return
    }

    foreach ($level in 20, 10) {
        if ($Reading.Percent -le $level -and $script:WarnedLevels -notcontains $level) {
            $script:WarnedLevels += $level
            $text = "Akku bei $($Reading.Percent) %."
            if ($script:DrawSamples.Count -gt 0) {
                $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
                $text += ' Bei aktuell {0:N1} W noch ca. {1}.' -f $avg, (Format-Duration -Hours ($Reading.RemainingWh / $avg))
            }
            Show-Balloon -Title "$(E 0x1F50B) Akku niedrig" -Text $text
            break
        }
    }
}

function Show-BatteryDetails {
    if (-not $MetricsAvailable) { return }

    $r = Get-BatteryReading
    if (-not $r) {
        [System.Windows.Forms.MessageBox]::Show(
            'Es wurde kein Akku gefunden - die Verbrauchsmessung funktioniert nur auf Geraeten mit Akku.',
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $lines = @()
    $mode = Get-CurrentMode
    if ($mode -and $Labels.ContainsKey($mode)) { $lines += "Aktives Profil: $($Labels[$mode])" }

    if ($r.OnAc) { $lines += 'Stromquelle: Netzteil' } else { $lines += 'Stromquelle: Akku' }
    $lines += ('Ladestand: {0} % ({1} von {2} Wh)' -f $r.Percent, $r.RemainingWh, $r.FullWh)

    if ($script:DrawSamples.Count -gt 0) {
        $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
        $lines += ''
        $lines += ('Aktueller Verbrauch: {0:N1} W (Mittel der letzten {1} Messungen)' -f $avg, $script:DrawSamples.Count)
        $lines += ('Restlaufzeit: ca. {0}' -f (Format-Duration -Hours ($r.RemainingWh / $avg)))
        $lines += ('Bei vollem Akku: ca. {0}' -f (Format-Duration -Hours ($r.FullWh / $avg)))
    } else {
        $lines += ''
        $lines += 'Verbrauch: am Netzteil nicht messbar (nur im Akkubetrieb).'
    }

    if ($r.DesignWh -gt 0 -and $r.FullWh -gt 0) {
        $health = [int][Math]::Round(100.0 * $r.FullWh / $r.DesignWh)
        $lines += ''
        $lines += ('Akku-Zustand: {0} % ({1} von {2} Wh im Neuzustand)' -f $health, $r.FullWh, $r.DesignWh)
    }
    if ($r.CycleCount -gt 0) { $lines += "Ladezyklen: $($r.CycleCount)" }

    # Langzeit-Durchschnitt aus dem Protokoll - aussagekraeftiger als die
    # kurze Messung direkt nach dem Umschalten.
    $stats = Get-LogStatistics
    if ($stats.Count -gt 0) {
        $lines += ''
        $lines += 'Durchschnitt aus dem Verbrauchsprotokoll:'
        foreach ($stat in $stats) {
            $name = $stat.Profil
            if ($ShortLabels.ContainsKey($name)) { $name = $ShortLabels[$name] }
            $runtimeText = '-'
            if ($r.FullWh -gt 0 -and $stat.Watt -gt 0) {
                $runtimeText = Format-Duration -Hours ($r.FullWh / $stat.Watt)
            }
            $lines += ('  {0,-13} {1,6:N1} W  ->  ca. {2} bei vollem Akku   ({3} Messungen)' -f `
                $name, $stat.Watt, $runtimeText, $stat.Anzahl)
        }
    }

    $metrics = Get-ProfileMetrics
    if ($metrics) {
        $lines += ''
        $lines += 'Letzte Messung direkt nach dem Profilwechsel:'
        foreach ($key in 'Gaming', 'Balanced', 'Travel') {
            if ($metrics.PSObject.Properties.Name -notcontains $key) { continue }
            $entry = $metrics.$key
            if (-not $entry -or [double]$entry.Watt -le 0) { continue }
            $runtime = Format-Duration -Hours ([double]$entry.RuntimeFullH)
            $lines += ('  {0,-13} {1,6:N1} W  ->  ca. {2} bei vollem Akku   ({3})' -f `
                $ShortLabels[$key], [double]$entry.Watt, $runtime, $entry.When)
        }
    }

    [System.Windows.Forms.MessageBox]::Show(
        ($lines -join "`n"),
        'PowerProfile Switcher - Akku & Verbrauch',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

# --------------------------------------------------------------------------
# Tray-Icon und Menue
# --------------------------------------------------------------------------

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $Icons.Unknown
$notifyIcon.Text = 'PowerProfile Switcher'
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

# Kopfzeile mit Live-Verbrauch - Klick oeffnet die Detailansicht.
$itemStatus = $menu.Items.Add("$(E 0x26A1)  Verbrauch wird gemessen ...")
$itemStatus.Add_Click({ Show-BatteryDetails })

$menu.Items.Add('-') | Out-Null

$itemGaming = $menu.Items.Add("$(E 0x1F3AE)  Gaming (Hoechstleistung)")
$itemGaming.ShortcutKeyDisplayString = 'Strg+Alt+1'
$itemGaming.Add_Click({ Invoke-Profile -Name 'Gaming' })

$itemBalanced = $menu.Items.Add("$(E 0x2696)  Ausgeglichen")
$itemBalanced.ShortcutKeyDisplayString = 'Strg+Alt+2'
$itemBalanced.Add_Click({ Invoke-Profile -Name 'Balanced' })

$itemTravel = $menu.Items.Add("$(E 0x1F50B)  Unterwegs (Akku sparen)")
$itemTravel.ShortcutKeyDisplayString = 'Strg+Alt+3'
$itemTravel.Add_Click({ Invoke-Profile -Name 'Travel' })

$menu.Items.Add('-') | Out-Null

$itemAuto = $menu.Items.Add('Automatisch bei Netzteil ab/an umschalten')
$itemAuto.Checked = [bool]$Settings.AutoSwitch
$itemAuto.Add_Click({
    $Settings.AutoSwitch = -not [bool]$Settings.AutoSwitch
    $itemAuto.Checked = [bool]$Settings.AutoSwitch
    Save-Settings
})

$itemDiag = $menu.Items.Add('Diagnose ausfuehren (Bericht oeffnen)')
$itemDiag.Add_Click({
    $diagScript = Join-Path $ScriptDir 'Test-PowerProfile.ps1'
    if (-not (Test-Path $diagScript)) {
        [System.Windows.Forms.MessageBox]::Show(
            'Test-PowerProfile.ps1 wurde nicht gefunden. Bitte Install.ps1 erneut ausfuehren.',
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$diagScript`""
    )
}.GetNewClosure())

$xmgCcPaths = @(
    "$env:ProgramFiles\XMG\XMG Control Center\XMG Control Center.exe",
    "${env:ProgramFiles(x86)}\XMG\XMG Control Center\XMG Control Center.exe",
    "$env:ProgramFiles\Tongfang\Control Center\Control Center.exe"
)
$xmgCcExe = $xmgCcPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($xmgCcExe) {
    $itemCc = $menu.Items.Add('XMG Control Center oeffnen (Luefter/RGB)')
    $itemCc.Add_Click({ Start-Process -FilePath $xmgCcExe }.GetNewClosure())
}

$menu.Items.Add('-') | Out-Null

$itemExit = $menu.Items.Add('Beenden')
$itemExit.Add_Click({
    if ($script:hotkeyWindow) { try { $script:hotkeyWindow.Dispose() } catch { } }
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$notifyIcon.ContextMenuStrip = $menu
$notifyIcon.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $menu.Show([System.Windows.Forms.Cursor]::Position)
    }
})

# NotifyIcon.Text ist auf 63 Zeichen begrenzt - laengere Texte wuerden
# eine Ausnahme werfen.
function Set-TrayTooltip {
    param([string]$Text)
    if ($Text.Length -gt 63) { $Text = $Text.Substring(0, 60) + '...' }
    $notifyIcon.Text = $Text
}

# Aktuelles Profil im Icon/Tooltip/Menue widerspiegeln, Messwert aufnehmen
# und das Icon in der Taskleiste "am Leben halten".
function Update-TrayState {
    $notifyIcon.Visible = $true

    $mode = Get-CurrentMode
    $tooltip = 'PowerProfile Switcher'
    if ($mode -and $Icons.ContainsKey($mode)) {
        $notifyIcon.Icon = $Icons[$mode]
        $tooltip = $ShortLabels[$mode]
    } else {
        $notifyIcon.Icon = $Icons.Unknown
    }

    $itemGaming.Checked   = ($mode -eq 'Gaming')
    $itemBalanced.Checked = ($mode -eq 'Balanced')
    $itemTravel.Checked   = ($mode -eq 'Travel')

    $reading = $null
    if ($MetricsAvailable) { $reading = Get-BatteryReading }

    # Gaming erst ab Mindest-Ladestand anbieten
    if (Test-GamingAllowed -Reading $reading) {
        $itemGaming.Enabled = $true
        $itemGaming.Text    = "$(E 0x1F3AE)  Gaming (Hoechstleistung)"
    } else {
        $itemGaming.Enabled = $false
        $itemGaming.Text    = "$(E 0x1F3AE)  Gaming - erst ab $GamingMinBatteryPercent % Akku"
    }

    $status = Get-PowerStatusText -Reading $reading
    $itemStatus.Text = "$(E 0x26A1)  $($status.Menu)"
    if ($status.Tip) { $tooltip = "$tooltip - $($status.Tip)" }
    Set-TrayTooltip -Text $tooltip

    if ($reading) {
        Write-PowerLog -Reading $reading -ModeName $mode
        Test-BatteryWarning -Reading $reading
        Invoke-AutoSwitch -Reading $reading
    }
}

# --- Globale Hotkeys (Strg+Alt+1/2/3) ------------------------------------
$hotkeyWindow = $null
try {
    if (-not ('PowerProfileSwitcher.HotkeyWindow' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace PowerProfileSwitcher {
    public class HotkeyWindow : NativeWindow, IDisposable {
        [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        private const int WM_HOTKEY = 0x0312;

        public int LastId = 0;
        public event EventHandler HotkeyPressed;

        public HotkeyWindow() {
            CreateHandle(new CreateParams());
        }

        public bool Register(int id, uint modifiers, uint key) {
            return RegisterHotKey(this.Handle, id, modifiers, key);
        }

        protected override void WndProc(ref Message m) {
            if (m.Msg == WM_HOTKEY) {
                LastId = m.WParam.ToInt32();
                if (HotkeyPressed != null) { HotkeyPressed(this, EventArgs.Empty); }
            }
            base.WndProc(ref m);
        }

        public void Dispose() {
            for (int i = 1; i <= 3; i++) { UnregisterHotKey(this.Handle, i); }
            DestroyHandle();
        }
    }
}
'@
    }

    $hotkeyWindow = New-Object PowerProfileSwitcher.HotkeyWindow
    $hotkeyWindow.add_HotkeyPressed({
        switch ($script:hotkeyWindow.LastId) {
            1 { Invoke-Profile -Name 'Gaming' }
            2 { Invoke-Profile -Name 'Balanced' }
            3 { Invoke-Profile -Name 'Travel' }
        }
    })

    # MOD_ALT (0x1) + MOD_CONTROL (0x2) = 3, Tasten '1'..'3' = 0x31..0x33
    $registered = @()
    if ($hotkeyWindow.Register(1, 3, 0x31)) { $registered += 'Strg+Alt+1' }
    if ($hotkeyWindow.Register(2, 3, 0x32)) { $registered += 'Strg+Alt+2' }
    if ($hotkeyWindow.Register(3, 3, 0x33)) { $registered += 'Strg+Alt+3' }

    if ($registered.Count -lt 3) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Nicht alle Hotkeys konnten registriert werden (belegt?): $($registered -join ', ')" |
            Add-Content -Path $LogFile -Encoding UTF8
    }
} catch {
    try {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Hotkeys nicht verfuegbar: $_" |
            Add-Content -Path $LogFile -Encoding UTF8
    } catch { }
}

# Regelmaessiger Herzschlag (alle 15s): Icon sichtbar halten, Messpunkt
# aufnehmen, Akku-Warnung und Auto-Umschaltung pruefen.
$heartbeat = New-Object System.Windows.Forms.Timer
$heartbeat.Interval = 15000
$heartbeat.Add_Tick({ Update-TrayState })
$heartbeat.Start()

# Einmaliger "Kick" ein paar Sekunden nach einem Profilwechsel, damit die
# Anzeige schneller aktualisiert wird als der naechste Herzschlag.
$kickTimer = New-Object System.Windows.Forms.Timer
$kickTimer.Interval = 4000
$kickTimer.Add_Tick({
    $kickTimer.Stop()
    Update-TrayState
})

Update-TrayState

[System.Windows.Forms.Application]::Run()
