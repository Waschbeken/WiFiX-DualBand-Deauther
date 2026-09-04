#Requires -Version 5.1
<#
    Start-Tray.ps1

    Zeigt ein Symbol im Windows-Infobereich (Tray) mit einem Rechtsklick-
    Menue zum sofortigen Umschalten der Energieprofile. Das Skript selbst
    laeuft OHNE Administratorrechte - es loest lediglich die vorher per
    Install.ps1 angelegten geplanten Aufgaben aus, die bereits mit
    erhoehten Rechten laufen. Dadurch erscheint kein UAC-Fenster beim
    Umschalten.

    Zusaetzlich misst es im Hintergrund laufend den Akku-Verbrauch in Watt
    und rechnet daraus die voraussichtliche Restlaufzeit hoch (siehe
    PowerMetrics.ps1).

    Das Icon haelt sich selbst am Leben: ein Timer setzt regelmaessig
    "Visible = true" erneut, falls Windows das Icon nach einem
    Grafiktreiber-Reset (z.B. beim GPU-Umschalten) oder einem
    Explorer-Neustart aus der Taskleiste entfernt hat.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$TaskPrefix  = 'PowerProfileSwitcher-'
$StateDir    = Join-Path $env:LOCALAPPDATA 'PowerProfileSwitcher'
$CurrentFile = Join-Path $StateDir 'current.json'
$LogFile     = Join-Path $StateDir 'tray.log'
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# Funktionen zur Verbrauchsmessung einbinden (Watt / Restlaufzeit).
$MetricsScript    = Join-Path $PSScriptRoot 'PowerMetrics.ps1'
$MetricsAvailable = Test-Path $MetricsScript
if ($MetricsAvailable) { . $MetricsScript }

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

# Gleitender Mittelwert der letzten Messpunkte, damit die Wattanzeige
# nicht bei jeder kurzen Lastspitze springt.
$DrawSamples    = @()
$MaxDrawSamples = 8

function Invoke-Profile {
    param([string]$Name)
    try {
        Start-ScheduledTask -TaskName "$TaskPrefix$Name" -ErrorAction Stop
        $script:DrawSamples = @()   # alte Messwerte gelten fuer das alte Profil
        $script:kickTimer.Stop()
        $script:kickTimer.Start()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Konnte Profil '$Name' nicht aktivieren. Bitte zuerst Install.ps1 (als Administrator) ausfuehren.",
            'PowerProfile Switcher',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
}

# Liest den Akku aus, pflegt den gleitenden Mittelwert und liefert kurze
# Texte fuer Menue und Tooltip.
function Get-PowerStatusText {
    if (-not $MetricsAvailable) { return @{ Menu = 'Verbrauchsmessung nicht verfuegbar'; Tip = '' } }

    $r = Get-BatteryReading
    if (-not $r) { return @{ Menu = 'Kein Akku erkannt'; Tip = '' } }

    if ($r.DrawWatt -gt 0) {
        $script:DrawSamples += $r.DrawWatt
        if ($script:DrawSamples.Count -gt $MaxDrawSamples) {
            $script:DrawSamples = @($script:DrawSamples | Select-Object -Last $MaxDrawSamples)
        }
    } elseif ($r.OnAc) {
        $script:DrawSamples = @()
    }

    if ($script:DrawSamples.Count -eq 0) {
        if ($r.OnAc) {
            return @{ Menu = "Am Netzteil - Akku $($r.Percent) %"; Tip = "Netz - $($r.Percent) %" }
        }
        return @{ Menu = "Akku $($r.Percent) % - Verbrauch wird gemessen ..."; Tip = "$($r.Percent) %" }
    }

    $avg = [Math]::Round((($script:DrawSamples | Measure-Object -Average).Average), 1)
    $rest = Format-Duration -Hours ($r.RemainingWh / $avg)

    return @{
        Menu = ('{0:N1} W - Akku {1} %, noch ca. {2}' -f $avg, $r.Percent, $rest)
        Tip  = ('{0:N1} W, ~{1}' -f $avg, $rest)
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

    $metrics = Get-ProfileMetrics
    if ($metrics) {
        $lines += ''
        $lines += 'Zuletzt beim Profilwechsel gemessen:'
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
$itemGaming.Add_Click({ Invoke-Profile -Name 'Gaming' })

$itemBalanced = $menu.Items.Add("$(E 0x2696)  Ausgeglichen")
$itemBalanced.Add_Click({ Invoke-Profile -Name 'Balanced' })

$itemTravel = $menu.Items.Add("$(E 0x1F50B)  Unterwegs (Akku sparen)")
$itemTravel.Add_Click({ Invoke-Profile -Name 'Travel' })

$menu.Items.Add('-') | Out-Null

$xmgCcPaths = @(
    "$env:ProgramFiles\XMG\XMG Control Center\XMG Control Center.exe",
    "${env:ProgramFiles(x86)}\XMG\XMG Control Center\XMG Control Center.exe",
    "$env:ProgramFiles\Tongfang\Control Center\Control Center.exe"
)
$xmgCcExe = $xmgCcPaths | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($xmgCcExe) {
    $itemCc = $menu.Items.Add('XMG Control Center oeffnen (Luefter/RGB)')
    $itemCc.Add_Click({ Start-Process -FilePath $xmgCcExe }.GetNewClosure())
    $menu.Items.Add('-') | Out-Null
}

$itemExit = $menu.Items.Add('Beenden')
$itemExit.Add_Click({
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

# Aktuelles Profil im Icon/Tooltip/Menue widerspiegeln und das Icon in der
# Taskleiste "am Leben halten" (Selbstheilung nach Treiber-Reset o.ae.).
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

    $status = Get-PowerStatusText
    $itemStatus.Text = "$(E 0x26A1)  $($status.Menu)"
    if ($status.Tip) { $tooltip = "$tooltip - $($status.Tip)" }
    Set-TrayTooltip -Text $tooltip
}

# Regelmaessiger Herzschlag (alle 15s): Icon erneut sichtbar machen, falls
# es aus irgendeinem Grund aus der Taskleiste verschwunden ist, und dabei
# gleich einen neuen Messpunkt fuer den Verbrauch aufnehmen.
$heartbeat = New-Object System.Windows.Forms.Timer
$heartbeat.Interval = 15000
$heartbeat.Add_Tick({ Update-TrayState })
$heartbeat.Start()

# Einmaliger "Kick" ein paar Sekunden nach einem Profilwechsel, damit die
# Anzeige schneller aktualisiert wird als der naechste Herzschlag (die
# geplante Aufgabe braucht 1-3s, bis powercfg/GPU/Refresh-Rate fertig sind).
$kickTimer = New-Object System.Windows.Forms.Timer
$kickTimer.Interval = 4000
$kickTimer.Add_Tick({
    $kickTimer.Stop()
    Update-TrayState
})

Update-TrayState

[System.Windows.Forms.Application]::Run()
