#Requires -Version 5.1
<#
    Start-Tray.ps1

    Zeigt ein Symbol im Windows-Infobereich (Tray) mit einem Rechtsklick-
    Menue zum sofortigen Umschalten der Energieprofile. Das Skript selbst
    laeuft OHNE Administratorrechte - es loest lediglich die vorher per
    Install.ps1 angelegten geplanten Aufgaben aus, die bereits mit
    erhoehten Rechten laufen. Dadurch erscheint kein UAC-Fenster beim
    Umschalten.

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

function Invoke-Profile {
    param([string]$Name)
    try {
        Start-ScheduledTask -TaskName "$TaskPrefix$Name" -ErrorAction Stop
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

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = $Icons.Unknown
$notifyIcon.Text = 'PowerProfile Switcher'
$notifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemGaming = $menu.Items.Add("$(E 0x1F3AE)  Gaming (Hoechstleistung)")
$itemGaming.Add_Click({ Invoke-Profile -Name 'Gaming' })

$itemBalanced = $menu.Items.Add("$(E 0x2696)  Ausgeglichen")
$itemBalanced.Add_Click({ Invoke-Profile -Name 'Balanced' })

$itemTravel = $menu.Items.Add("$(E 0x1F50B)  Unterwegs (Akku sparen)")
$itemTravel.Add_Click({ Invoke-Profile -Name 'Travel' })

$menu.Items.Add('-') | Out-Null

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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

# Aktuelles Profil im Icon/Tooltip/Menue widerspiegeln und das Icon in der
# Taskleiste "am Leben halten" (Selbstheilung nach Treiber-Reset o.ae.).
function Update-TrayState {
    $notifyIcon.Visible = $true

    $mode = Get-CurrentMode
    if ($mode -and $Icons.ContainsKey($mode)) {
        $notifyIcon.Icon = $Icons[$mode]
        $notifyIcon.Text = "PowerProfile Switcher - $($Labels[$mode])"
    } else {
        $notifyIcon.Icon = $Icons.Unknown
        $notifyIcon.Text = 'PowerProfile Switcher'
    }

    $itemGaming.Checked   = ($mode -eq 'Gaming')
    $itemBalanced.Checked = ($mode -eq 'Balanced')
    $itemTravel.Checked   = ($mode -eq 'Travel')
}

# Regelmaessiger Herzschlag (alle 15s): Icon erneut sichtbar machen, falls
# es aus irgendeinem Grund aus der Taskleiste verschwunden ist.
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
